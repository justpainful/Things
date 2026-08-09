import Foundation
import XCTest
import CryptoKit
@testable import ThingsCore

final class SecretBoxTests: XCTestCase {

    let key = SymmetricKey(size: .bits256)
    let thingID = "01920000-0000-7000-8000-00000000aaaa"
    let fieldID = "01920000-0000-7000-8000-00000000bbbb"

    func testRoundTrip() throws {
        let envelope = try SecretBox.sealString("not-a-real-password", key: key, thingID: thingID, fieldID: fieldID)
        XCTAssertTrue(SecretBox.looksLikeEnvelope(envelope))
        let opened = try SecretBox.openString(envelope, key: key, thingID: thingID, fieldID: fieldID)
        XCTAssertEqual(opened, "not-a-real-password")
    }

    /// The reason the AAD exists: a ciphertext blob must not be transplantable into a
    /// different Thing to trick the app into decrypting it somewhere it does not belong.
    func testCiphertextCannotBeMovedToAnotherThing() throws {
        let envelope = try SecretBox.sealString("value", key: key, thingID: thingID, fieldID: fieldID)
        XCTAssertThrowsError(
            try SecretBox.openString(envelope, key: key,
                                     thingID: "01920000-0000-7000-8000-00000000cccc",
                                     fieldID: fieldID)
        )
        XCTAssertThrowsError(
            try SecretBox.openString(envelope, key: key,
                                     thingID: thingID,
                                     fieldID: "01920000-0000-7000-8000-00000000dddd")
        )
    }

    func testWrongKeyFails() throws {
        let envelope = try SecretBox.sealString("value", key: key, thingID: thingID, fieldID: fieldID)
        XCTAssertThrowsError(
            try SecretBox.openString(envelope, key: SymmetricKey(size: .bits256),
                                     thingID: thingID, fieldID: fieldID)
        )
    }

    func testTamperingIsDetected() throws {
        var envelope = try SecretBox.sealString("value", key: key, thingID: thingID, fieldID: fieldID)
        envelope[envelope.count - 1] ^= 0xFF
        XCTAssertThrowsError(try SecretBox.openString(envelope, key: key, thingID: thingID, fieldID: fieldID))
    }

    func testHeaderShape() throws {
        let envelope = try SecretBox.seal(Data("x".utf8), key: key, thingID: thingID, fieldID: fieldID)
        let bytes = [UInt8](envelope)
        XCTAssertEqual(Array(bytes[0..<4]), Array("TENV".utf8))
        XCTAssertEqual(bytes[4], 1)                                  // version
        XCTAssertEqual(bytes[5], 1)                                  // AES-256-GCM
        XCTAssertEqual(bytes[6], UInt8(SecretBox.nonceByteCount))    // 12
        XCTAssertEqual(SecretBox.headerByteCount, 7)
        XCTAssertEqual(envelope.count,
                       SecretBox.headerByteCount + SecretBox.nonceByteCount + 1 + SecretBox.tagByteCount)
    }

    /// The header is fed to GCM as additional data, so rewriting the version or algorithm
    /// byte of a captured envelope must not open — that is the downgrade-forgery defence.
    func testHeaderIsAuthenticated() throws {
        for index in [4, 5, 6] {
            var envelope = try SecretBox.sealString("value", key: key, thingID: thingID, fieldID: fieldID)
            envelope[index] = envelope[index] &+ 1
            XCTAssertThrowsError(
                try SecretBox.openString(envelope, key: key, thingID: thingID, fieldID: fieldID),
                "byte \(index) of the header must be authenticated"
            )
        }
    }

    func testAdditionalDataIsConcatenation() {
        let aad = SecretBox.additionalData(thingID: "AAA", fieldID: "BBB")
        XCTAssertEqual(String(data: aad, encoding: .utf8), "AAABBB")
    }
}

final class KeyHierarchyTests: XCTestCase {

    func testWrapUnwrap() throws {
        let dek = KeyHierarchy.generateDEK()
        let kek = SymmetricKey(size: .bits256)
        let wrapped = try KeyHierarchy.wrap(dek, with: kek, context: KeyHierarchy.Context.pinWrap)
        let unwrapped = try KeyHierarchy.unwrap(wrapped, with: kek, context: KeyHierarchy.Context.pinWrap)
        XCTAssertEqual(unwrapped.withUnsafeBytes { Data($0) }, dek.withUnsafeBytes { Data($0) })
    }

    /// A PIN-wrapped DEK must not open as a device-wrapped one.
    func testContextIsBinding() throws {
        let dek = KeyHierarchy.generateDEK()
        let kek = SymmetricKey(size: .bits256)
        let wrapped = try KeyHierarchy.wrap(dek, with: kek, context: KeyHierarchy.Context.pinWrap)
        XCTAssertThrowsError(try KeyHierarchy.unwrap(wrapped, with: kek, context: KeyHierarchy.Context.deviceWrap))
    }

    func testScryptIsDeterministic() throws {
        let salt = Data(repeating: 0x11, count: 16)
        let a = try KeyHierarchy.deriveKEK(pin: "000000", salt: salt, parameters: .fast)
        let b = try KeyHierarchy.deriveKEK(pin: "000000", salt: salt, parameters: .fast)
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testDifferentPINsDeriveDifferentKeys() throws {
        let salt = Data(repeating: 0x11, count: 16)
        let a = try KeyHierarchy.deriveKEK(pin: "000000", salt: salt, parameters: .fast)
        let b = try KeyHierarchy.deriveKEK(pin: "000001", salt: salt, parameters: .fast)
        XCTAssertNotEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testLeadingZeroesArePartOfThePIN() throws {
        let salt = Data(repeating: 0x22, count: 16)
        let a = try KeyHierarchy.deriveKEK(pin: "001234", salt: salt, parameters: .fast)
        let b = try KeyHierarchy.deriveKEK(pin: "1234", salt: salt, parameters: .fast)
        XCTAssertNotEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testLockoutEscalates() {
        XCTAssertEqual(KeyHierarchy.lockoutSeconds(afterFailedAttempts: 0), 0)
        XCTAssertEqual(KeyHierarchy.lockoutSeconds(afterFailedAttempts: 3), 1)
        XCTAssertEqual(KeyHierarchy.lockoutSeconds(afterFailedAttempts: 5), 30)
        XCTAssertGreaterThan(KeyHierarchy.lockoutSeconds(afterFailedAttempts: 9), 300)
    }

    func testRawKeyIsSixtyFourHexCharacters() {
        let hex = KeyHierarchy.sqlcipherRawKey(KeyHierarchy.generateDEK())
        XCTAssertEqual(hex.count, 64)
        XCTAssertNotNil(Hex.decode(hex))
    }
}

final class VaultTests: XCTestCase {

    func makeVault() -> (Vault, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString).json")
        // A software device key store rooted at a unique service name, so tests never
        // collide with each other or with a real install.
        let vault = Vault(storage: FileVaultStorage(url: url),
                          deviceKeyStore: DeviceKeyStore(service: "com.things.tests.\(UUID().uuidString)",
                                                         account: "test"),
                          clock: FixedClock())
        return (vault, url)
    }

    func testInitialiseThenUnlockWithPIN() throws {
        let (vault, url) = makeVault()
        defer { try? FileManager.default.removeItem(at: url) }

        let dek = try vault.initialise(pin: "246810", parameters: .fast)
        let reopened = try vault.unlockWithPIN("246810")
        XCTAssertEqual(reopened.withUnsafeBytes { Data($0) }, dek.withUnsafeBytes { Data($0) })
    }

    func testWrongPINFailsAndCounts() throws {
        let (vault, url) = makeVault()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try vault.initialise(pin: "246810", parameters: .fast)
        XCTAssertThrowsError(try vault.unlockWithPIN("111111"))
        XCTAssertEqual(try vault.state().failedAttempts, 1)
        _ = try vault.unlockWithPIN("246810")
        XCTAssertEqual(try vault.state().failedAttempts, 0)
    }

    func testChangePINKeepsTheSameDEK() throws {
        let (vault, url) = makeVault()
        defer { try? FileManager.default.removeItem(at: url) }

        let dek = try vault.initialise(pin: "246810", parameters: .fast)
        try vault.changePIN(current: "246810", new: "135790")
        let reopened = try vault.unlockWithPIN("135790")
        XCTAssertEqual(reopened.withUnsafeBytes { Data($0) }, dek.withUnsafeBytes { Data($0) })
    }
}

final class EncryptedObjectStoreTests: XCTestCase {

    func makeStore() -> (EncryptedObjectStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("objects-\(UUID().uuidString)", isDirectory: true)
        return (EncryptedObjectStore(rootDirectory: root, dek: SymmetricKey(size: .bits256)), root)
    }

    func testRoundTripSmall() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let plaintext = Data("a small file, obviously fictional".utf8)
        let receipt = try store.store(plaintext)
        XCTAssertTrue(receipt.isNewlyStored)
        XCTAssertEqual(receipt.hash, EncryptedObjectStore.sha256Hex(plaintext))

        let loaded = try store.load(hash: receipt.hash, encKeyWrap: receipt.encKeyWrap)
        XCTAssertEqual(loaded, plaintext)
    }

    func testRoundTripAcrossFrames() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two and a bit frames, so the framing is genuinely exercised.
        var plaintext = Data()
        plaintext.append(contentsOf: (0..<(EncryptedObjectStore.frameByteCount * 2 + 4096)).map { UInt8($0 % 251) })
        let receipt = try store.store(plaintext)
        let loaded = try store.load(hash: receipt.hash, encKeyWrap: receipt.encKeyWrap)
        XCTAssertEqual(loaded.count, plaintext.count)
        XCTAssertEqual(EncryptedObjectStore.sha256Hex(loaded), receipt.hash)
    }

    func testEmptyObject() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = try store.store(Data())
        let loaded = try store.load(hash: receipt.hash, encKeyWrap: receipt.encKeyWrap)
        XCTAssertEqual(loaded.count, 0)
    }

    func testDedupeIsAPrimaryKeyHit() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let plaintext = Data("the same logo in four Things".utf8)
        let first = try store.store(plaintext)
        let second = try store.store(plaintext)
        XCTAssertTrue(first.isNewlyStored)
        XCTAssertFalse(second.isNewlyStored)
        XCTAssertEqual(first.hash, second.hash)
    }

    func testFanOutPath() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = store.url(for: "abcdef1234567890")
        XCTAssertEqual(url.lastPathComponent, "abcdef1234567890")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "cd")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "ab")
    }

    func testCorruptionIsDetected() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = try store.store(Data("tamper with me".utf8))
        let path = store.url(for: receipt.hash)
        var bytes = try Data(contentsOf: path)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: path)
        XCTAssertThrowsError(try store.load(hash: receipt.hash, encKeyWrap: receipt.encKeyWrap))
    }

    /// The normative container header — `spec/crypto.md` §5.
    func testContainerHeaderShape() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = try store.store(Data("header shape".utf8))
        XCTAssertEqual(receipt.encNonce.count, 8)
        let bytes = [UInt8](try Data(contentsOf: store.url(for: receipt.hash)))
        XCTAssertEqual(Array(bytes[0..<4]), Array("TOBJ".utf8))
        XCTAssertEqual(bytes[4], 1)                                     // version
        XCTAssertEqual(bytes[5], 1)                                     // AES-256-GCM
        XCTAssertEqual(Array(bytes[6..<10]), [0x00, 0x10, 0x00, 0x00])  // 1 MiB, big endian
        XCTAssertEqual(Array(bytes[10..<18]), [UInt8](receipt.encNonce))
        XCTAssertEqual(EncryptedObjectStore.headerByteCount, 18)
        // header ‖ length(4) ‖ ciphertext(12) ‖ tag(16)
        XCTAssertEqual(bytes.count, 18 + 4 + 12 + 16)
    }

    /// Dropping the trailing frame must not yield a shorter but valid file: the last-frame
    /// flag is in the AAD precisely so truncation is detectable.
    func testTruncationIsDetected() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var plaintext = Data()
        plaintext.append(contentsOf: (0..<(EncryptedObjectStore.frameByteCount + 32)).map { UInt8($0 % 251) })
        let receipt = try store.store(plaintext)
        let path = store.url(for: receipt.hash)
        let bytes = [UInt8](try Data(contentsOf: path))

        // Keep the header and the first frame only.
        var length = 0
        for index in 18..<22 { length = length << 8 | Int(bytes[index]) }
        try Data(bytes[0..<(18 + 4 + length)]).write(to: path)
        XCTAssertThrowsError(try store.load(hash: receipt.hash, encKeyWrap: receipt.encKeyWrap))
    }

    func testRangeReadCrossesFrames() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var plaintext = Data()
        plaintext.append(contentsOf: (0..<(EncryptedObjectStore.frameByteCount + 4096)).map { UInt8($0 % 251) })
        let receipt = try store.store(plaintext)

        let offset = EncryptedObjectStore.frameByteCount - 10
        let range = try store.loadRange(hash: receipt.hash,
                                        encKeyWrap: receipt.encKeyWrap,
                                        offset: offset,
                                        length: 40)
        XCTAssertEqual(range, EncryptedObjectStore.slice(plaintext, offset: offset, length: 40))

        let head = try store.loadRange(hash: receipt.hash,
                                       encKeyWrap: receipt.encKeyWrap,
                                       offset: 0,
                                       length: 5)
        XCTAssertEqual(head, EncryptedObjectStore.slice(plaintext, offset: 0, length: 5))

        let firstFrame = try store.loadFrame(hash: receipt.hash,
                                             encKeyWrap: receipt.encKeyWrap,
                                             frameIndex: 0)
        XCTAssertEqual(firstFrame.count, EncryptedObjectStore.frameByteCount)
    }
}
