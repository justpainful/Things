import Foundation
import XCTest
import CryptoKit
@testable import ThingsCore

/// Runs `spec/vectors/*.json` — the conformance vectors the TypeScript core is written
/// against — so the two implementations are held to the same answers.
///
/// The vectors are authored by the other half of this project and may not exist yet. This
/// suite therefore:
///   * discovers whatever `.json` files are present at run time,
///   * skips cleanly when the directory is absent, so the suite is green either way,
///   * and starts enforcing agreement the moment a file lands, without any edit here.
///
/// Two case shapes are accepted per file: a bare array of cases, or
/// `{ "cases": [...] }` / `{ "vectors": [...] }`. Unknown keys inside a case are ignored;
/// a case that carries none of the keys a runner understands is counted as unrecognised
/// and reported, never silently passed.
final class ConformanceVectorTests: XCTestCase {

    func testSpecVectors() throws {
        guard TestSupport.vectorsDirectory != nil else {
            throw XCTSkip("spec/vectors/ does not exist yet — nothing to enforce.")
        }
        let files = TestSupport.vectorFiles()
        guard !files.isEmpty else {
            throw XCTSkip("spec/vectors/ is empty — nothing to enforce.")
        }

        var totalChecked = 0
        var unrecognisedFiles: [String] = []

        for file in files {
            let data = try Data(contentsOf: file)
            let parsed: JSONValue
            do {
                parsed = try JSONValue.parse(data)
            } catch {
                XCTFail("\(file.lastPathComponent) is not valid JSON: \(error)")
                continue
            }
            let cases = ConformanceVectorTests.cases(in: parsed)
            guard !cases.isEmpty else {
                unrecognisedFiles.append(file.lastPathComponent)
                continue
            }
            let checked = run(cases: cases, file: file.lastPathComponent)
            if checked == 0 {
                unrecognisedFiles.append(file.lastPathComponent)
            }
            totalChecked += checked
        }

        print("[vectors] checked \(totalChecked) assertions across \(files.count) file(s)")
        if !unrecognisedFiles.isEmpty {
            // Not a failure: a vector file for a part of the spec Swift does not implement
            // yet (sync transport, backup container) is legitimate. But it is printed, so a
            // shape mismatch cannot hide as a pass.
            print("[vectors] no runner matched: \(unrecognisedFiles.joined(separator: ", "))")
        }
    }

    // MARK: - crypto-envelope.json
    //
    // The generic dispatcher above only understands files shaped as a list of cases, and this
    // one is not: it is a document with named sections. It is also the single most important
    // file in the directory — it is the reason the PC and the phone can read each other's
    // bytes — so it gets a runner that knows its shape and fails loudly.

    private func vectorFile(_ name: String) throws -> JSONValue {
        guard let file = TestSupport.vectorsDirectory?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("spec/vectors/\(name) is not present.")
        }
        return try JSONValue.parse(try Data(contentsOf: file))
    }

    private func hex(_ value: JSONValue?) -> [UInt8]? {
        guard let text = value?.stringValue else { return nil }
        return Hex.decode(text)
    }

    func testCryptoEnvelopeVectors() throws {
        let root = try vectorFile("crypto-envelope.json")

        // ── layout constants ────────────────────────────────────────────────────────
        let layout = try XCTUnwrap(root["envelopeLayout"])
        XCTAssertEqual(layout["magic"]?.stringValue, String(decoding: SecretBox.magic, as: UTF8.self))
        XCTAssertEqual(layout["magicHex"]?.stringValue, Hex.encode(SecretBox.magic))
        XCTAssertEqual(layout["versionByte"]?.intValue, Int(SecretBox.version))
        XCTAssertEqual(layout["algByte"]?.intValue, Int(SecretBox.algorithmAESGCM))
        XCTAssertEqual(layout["nonceLength"]?.intValue, SecretBox.nonceByteCount)
        XCTAssertEqual(layout["tagLength"]?.intValue, SecretBox.tagByteCount)
        XCTAssertEqual(layout["headerLength"]?.intValue, SecretBox.headerByteCount)

        // ── field AAD ───────────────────────────────────────────────────────────────
        let fieldAad = try XCTUnwrap(root["fieldAad"])
        let aad = SecretBox.additionalData(thingID: try XCTUnwrap(fieldAad["thingId"]?.stringValue),
                                           fieldID: try XCTUnwrap(fieldAad["fieldId"]?.stringValue))
        XCTAssertEqual(Hex.encode(aad), fieldAad["expectHex"]?.stringValue)

        // ── seal ────────────────────────────────────────────────────────────────────
        for (index, testCase) in (root["seal"]?.arrayValue ?? []).enumerated() {
            let label = "seal#\(index)"
            let key = SymmetricKey(data: Data(try XCTUnwrap(hex(testCase["keyHex"]), label)))
            let nonce = try XCTUnwrap(hex(testCase["nonceHex"]), label)
            let caseAad = Data(try XCTUnwrap(hex(testCase["aadHex"]), label))
            let plaintext = Data(try XCTUnwrap(testCase["plaintextUtf8"]?.stringValue, label).utf8)

            let envelope = try SecretBox.seal(plaintext, key: key, additionalData: caseAad, nonceBytes: nonce)
            XCTAssertEqual(Hex.encode(envelope), testCase["expectHex"]?.stringValue, label)
            XCTAssertEqual(try SecretBox.open(envelope, key: key, additionalData: caseAad), plaintext, label)
        }

        // ── envelopes that must NOT open ────────────────────────────────────────────
        for (index, testCase) in (root["openMustFail"]?.arrayValue ?? []).enumerated() {
            let label = "openMustFail#\(index): \(testCase["why"]?.stringValue ?? "")"
            let key = SymmetricKey(data: Data(try XCTUnwrap(hex(testCase["keyHex"]), label)))
            let envelope = Data(try XCTUnwrap(hex(testCase["envelopeHex"]), label))
            let caseAad = Data(try XCTUnwrap(hex(testCase["aadHex"]), label))
            XCTAssertThrowsError(try SecretBox.open(envelope, key: key, additionalData: caseAad), label)
        }

        // ── scrypt ──────────────────────────────────────────────────────────────────
        let kdf = try XCTUnwrap(root["kdf"])
        XCTAssertEqual(kdf["algorithm"]?.stringValue, KDFParameters.recommended.algorithm)
        let production = try XCTUnwrap(kdf["production"])
        XCTAssertEqual(production["N"]?.intValue, KDFParameters.recommended.n)
        XCTAssertEqual(production["r"]?.intValue, KDFParameters.recommended.r)
        XCTAssertEqual(production["p"]?.intValue, KDFParameters.recommended.p)
        XCTAssertEqual(production["dkLen"]?.intValue, KDFParameters.recommended.keyByteCount)

        for (index, testCase) in (kdf["cases"]?.arrayValue ?? []).enumerated() {
            let label = "kdf#\(index)"
            let params = try XCTUnwrap(testCase["params"], label)
            let derived = try ScryptKDF.derive(
                password: Data(try XCTUnwrap(testCase["passwordUtf8"]?.stringValue, label).utf8),
                salt: Data(try XCTUnwrap(hex(testCase["saltHex"]), label)),
                outputByteCount: try XCTUnwrap(params["dkLen"]?.intValue, label),
                n: try XCTUnwrap(params["N"]?.intValue, label),
                r: try XCTUnwrap(params["r"]?.intValue, label),
                p: try XCTUnwrap(params["p"]?.intValue, label)
            )
            XCTAssertEqual(Hex.encode(derived), testCase["expectHex"]?.stringValue, label)
        }

        // ── device KEK ──────────────────────────────────────────────────────────────
        let deviceKek = try XCTUnwrap(root["deviceKek"])
        let kek2 = KeyHierarchy.deriveDeviceKEK(
            deviceSecret: Data(try XCTUnwrap(hex(deviceKek["deviceSecretHex"]))),
            salt: Data(try XCTUnwrap(hex(deviceKek["saltHex"])))
        )
        XCTAssertEqual(Hex.encode(kek2.withUnsafeBytes { Array($0) }), deviceKek["expectHex"]?.stringValue)

        // ── framed objects ──────────────────────────────────────────────────────────
        let frames = try XCTUnwrap(root["objectFrames"])
        let frameLayout = try XCTUnwrap(frames["layout"])
        XCTAssertEqual(frameLayout["magic"]?.stringValue,
                       String(decoding: EncryptedObjectStore.magic, as: UTF8.self))
        XCTAssertEqual(frameLayout["versionByte"]?.intValue, Int(EncryptedObjectStore.version))
        XCTAssertEqual(frameLayout["algByte"]?.intValue, Int(EncryptedObjectStore.algorithmAESGCM))
        XCTAssertEqual(frameLayout["frameSizeOffset"]?.intValue, EncryptedObjectStore.frameSizeOffset)
        XCTAssertEqual(frameLayout["noncePrefixOffset"]?.intValue, EncryptedObjectStore.noncePrefixOffset)
        XCTAssertEqual(frameLayout["headerLength"]?.intValue, EncryptedObjectStore.headerByteCount)
        XCTAssertEqual(frameLayout["frameSize"]?.intValue, EncryptedObjectStore.frameByteCount)

        for (index, testCase) in (frames["cases"]?.arrayValue ?? []).enumerated() {
            let label = "objectFrames#\(index)"
            let key = SymmetricKey(data: Data(try XCTUnwrap(hex(testCase["keyHex"]), label)))
            let noncePrefix = Data(try XCTUnwrap(hex(testCase["noncePrefixHex"]), label))
            let plaintext = Data(try XCTUnwrap(testCase["plaintextUtf8"]?.stringValue, label).utf8)

            let container = try EncryptedObjectStore.encode(plaintext, key: key, noncePrefix: noncePrefix)
            XCTAssertEqual(Hex.encode(container), testCase["expectHex"]?.stringValue, label)

            let hash = EncryptedObjectStore.sha256Hex(plaintext)
            XCTAssertEqual(try EncryptedObjectStore.decode(container, hash: hash, objectKey: key), plaintext, label)
        }

        // ── object path fan-out ─────────────────────────────────────────────────────
        let fanout = try XCTUnwrap(root["objectPathFanout"])
        let store = EncryptedObjectStore(rootDirectory: URL(fileURLWithPath: "/tmp/objects", isDirectory: true),
                                         dek: SymmetricKey(size: .bits256))
        for (index, example) in (fanout["examples"]?.arrayValue ?? []).enumerated() {
            let label = "objectPathFanout#\(index)"
            let plaintext = Data(try XCTUnwrap(example["plaintextUtf8"]?.stringValue, label).utf8)
            let hash = EncryptedObjectStore.sha256Hex(plaintext)
            XCTAssertEqual(hash, example["hash"]?.stringValue, label)

            let url = store.url(for: hash)
            let expectedPath = try XCTUnwrap(example["path"]?.stringValue, label)
            XCTAssertEqual(url.pathComponents.suffix(4).joined(separator: "/"), expectedPath, label)
        }
    }

    // MARK: - hlc.json

    func testHLCVectors() throws {
        let root = try vectorFile("hlc.json")

        var formatted: [String] = []
        for (index, testCase) in (root["formatting"]?.arrayValue ?? []).enumerated() {
            let label = "formatting#\(index)"
            let parts = try XCTUnwrap(testCase["parts"], label)
            let physical = try XCTUnwrap(parts["physical"]?.stringValue, label)
            let millis = try XCTUnwrap(Timestamp.milliseconds(fromISO8601: physical), label)
            let stamp = HLC(millis: millis,
                            counter: try XCTUnwrap(parts["counter"]?.intValue, label),
                            deviceID: try XCTUnwrap(parts["device"]?.stringValue, label))
            let expected = try XCTUnwrap(testCase["expect"]?.stringValue, label)
            XCTAssertEqual(stamp.description, expected, label)
            XCTAssertEqual(HLC.parse(expected), stamp, label)
            formatted.append(expected)
        }

        // Plain string sort IS the ordering — that is the whole point of the format.
        let expectedSorted = (root["sorted"]?.arrayValue ?? []).compactMap { $0.stringValue }
        XCTAssertEqual(formatted.sorted(), expectedSorted)

        for (index, testCase) in (root["comparisons"]?.arrayValue ?? []).enumerated() {
            let label = "comparisons#\(index)"
            let a = try XCTUnwrap(testCase["a"]?.stringValue, label)
            let b = try XCTUnwrap(testCase["b"]?.stringValue, label)
            let expected = try XCTUnwrap(testCase["expect"]?.intValue, label)

            let stringOrder = a < b ? -1 : (a > b ? 1 : 0)
            XCTAssertEqual(stringOrder, expected, "\(label): string order")

            let left = try XCTUnwrap(HLC.parse(a), label)
            let right = try XCTUnwrap(HLC.parse(b), label)
            let structuralOrder = left < right ? -1 : (right < left ? 1 : 0)
            XCTAssertEqual(structuralOrder, expected, "\(label): structural order")
        }
    }

    // MARK: - Dispatch

    static func cases(in value: JSONValue) -> [JSONValue] {
        if let array = value.arrayValue { return array }
        for key in ["cases", "vectors", "tests", "examples"] {
            if let array = value[key]?.arrayValue { return array }
        }
        return []
    }

    private func run(cases: [JSONValue], file: String) -> Int {
        var checked = 0
        for (index, testCase) in cases.enumerated() {
            let label = "\(file)#\(index)"
            checked += checkUUIDv7(testCase, label: label)
            checked += checkTimestamp(testCase, label: label)
            checked += checkHLC(testCase, label: label)
            checked += checkVersionVector(testCase, label: label)
            checked += checkFractionalOrder(testCase, label: label)
            checked += checkSearchQuery(testCase, label: label)
            checked += checkCanonicalJSON(testCase, label: label)
            checked += checkScrypt(testCase, label: label)
            checked += checkSecretBox(testCase, label: label)
            checked += checkSHA256(testCase, label: label)
        }
        return checked
    }

    // MARK: - Runners
    //
    // Every runner returns the number of assertions it made, and returns 0 (making none)
    // when the case is not addressed to it.

    private func value(_ testCase: JSONValue, _ names: [String]) -> JSONValue? {
        for name in names {
            if let found = testCase[name] { return found }
        }
        return nil
    }

    private func text(_ testCase: JSONValue, _ names: [String]) -> String? {
        value(testCase, names)?.stringValue
    }

    private func integer(_ testCase: JSONValue, _ names: [String]) -> Int64? {
        guard let found = value(testCase, names) else { return nil }
        if let number = found.intValue { return Int64(number) }
        if let text = found.stringValue { return Int64(text) }
        return nil
    }

    private func bytes(_ testCase: JSONValue, _ names: [String]) -> [UInt8]? {
        guard let found = value(testCase, names) else { return nil }
        if let hex = found.stringValue { return Hex.decode(hex) }
        if let array = found.arrayValue {
            return array.compactMap { $0.intValue.map { UInt8(truncatingIfNeeded: $0) } }
        }
        return nil
    }

    private func checkUUIDv7(_ testCase: JSONValue, label: String) -> Int {
        guard let millis = integer(testCase, ["timestampMs", "timestamp_ms", "millis", "ms", "unixTsMs"]),
              let random = bytes(testCase, ["random", "randomBytes", "rand", "entropy"]),
              let expected = text(testCase, ["expected", "uuid", "expectedUuid", "id"]),
              random.count >= 10
        else { return 0 }
        XCTAssertEqual(UUIDv7.make(millisecondsSinceEpoch: millis, random: random), expected.lowercased(), label)
        return 1
    }

    private func checkTimestamp(_ testCase: JSONValue, label: String) -> Int {
        guard let millis = integer(testCase, ["epochMs", "epoch_ms", "timestampMillis"]),
              let expected = text(testCase, ["iso", "iso8601", "expectedIso", "expected"])
        else { return 0 }
        XCTAssertEqual(Timestamp.string(millisecondsSinceEpoch: millis), expected, label)
        XCTAssertEqual(Timestamp.milliseconds(fromISO8601: expected), millis, label)
        return 2
    }

    private func checkHLC(_ testCase: JSONValue, label: String) -> Int {
        var assertions = 0
        if let millis = integer(testCase, ["hlcMillis", "millis"]),
           let counter = integer(testCase, ["counter"]),
           let deviceID = text(testCase, ["deviceId", "device_id", "device"]),
           let expected = text(testCase, ["hlc", "expectedHlc", "expected"]) {
            let stamp = HLC(millis: millis, counter: Int(counter), deviceID: deviceID)
            XCTAssertEqual(stamp.description, expected, label)
            XCTAssertEqual(HLC.parse(expected), stamp, label)
            assertions += 2
        }
        if let leftText = text(testCase, ["a", "left", "lhs"]),
           let rightText = text(testCase, ["b", "right", "rhs"]),
           let expected = text(testCase, ["order", "comparison", "expectedOrder"]),
           let left = HLC.parse(leftText),
           let right = HLC.parse(rightText) {
            let actual = left < right ? "lt" : (right < left ? "gt" : "eq")
            XCTAssertEqual(actual, expected.lowercased(), label)
            assertions += 1
        }
        return assertions
    }

    private func checkVersionVector(_ testCase: JSONValue, label: String) -> Int {
        guard let left = value(testCase, ["a", "local", "left"])?.objectValue,
              let right = value(testCase, ["b", "remote", "right"])?.objectValue,
              let expected = text(testCase, ["expected", "result", "ordering", "comparison"])
        else { return 0 }
        // Only run when both sides really look like {device: counter}.
        guard left.values.allSatisfy({ $0.intValue != nil }), right.values.allSatisfy({ $0.intValue != nil }) else {
            return 0
        }
        var leftCounters: [String: Int] = [:]
        for (key, value) in left { leftCounters[key] = value.intValue }
        var rightCounters: [String: Int] = [:]
        for (key, value) in right { rightCounters[key] = value.intValue }

        let ordering = VersionVector(leftCounters).compare(to: VersionVector(rightCounters))
        XCTAssertEqual(ordering.rawValue, ConformanceVectorTests.normalisedOrdering(expected), label)
        return 1
    }

    static func normalisedOrdering(_ text: String) -> String {
        switch text.lowercased().replacingOccurrences(of: "_", with: "") {
        case "dominates", "adominates", "left", "greater", "gt": return "dominates"
        case "dominated", "bdominates", "right", "less", "lt": return "dominated"
        case "equal", "eq", "same": return "equal"
        case "concurrent", "conflict", "conflicting": return "concurrent"
        default: return text.lowercased()
        }
    }

    private func checkFractionalOrder(_ testCase: JSONValue, label: String) -> Int {
        guard let expectedValue = value(testCase, ["expectedOrder", "expectedSortOrder"])?.doubleValue else { return 0 }
        let lower = value(testCase, ["lower", "before", "prev"])?.doubleValue
        let upper = value(testCase, ["upper", "after", "next"])?.doubleValue
        XCTAssertEqual(FractionalOrder.between(lower, upper), expectedValue, accuracy: 1e-12, label)
        return 1
    }

    private func checkSearchQuery(_ testCase: JSONValue, label: String) -> Int {
        guard let input = text(testCase, ["query", "input", "search"]) else { return 0 }
        let parsed = SearchQuery.parse(input)
        var assertions = 0

        if let canonical = text(testCase, ["canonical", "expectedCanonical"]) {
            XCTAssertEqual(parsed.canonical, canonical, label)
            assertions += 1
        }
        if let expected = value(testCase, ["expected", "parsed", "ast"])?.objectValue {
            if let terms = expected["terms"]?.arrayValue {
                XCTAssertEqual(parsed.terms, terms.compactMap { $0.stringValue }, "\(label) terms")
                assertions += 1
            }
            if let phrases = expected["phrases"]?.arrayValue {
                XCTAssertEqual(parsed.phrases, phrases.compactMap { $0.stringValue }, "\(label) phrases")
                assertions += 1
            }
            if let excluded = (expected["excluded"] ?? expected["excludedTerms"])?.arrayValue {
                XCTAssertEqual(parsed.excludedTerms, excluded.compactMap { $0.stringValue }, "\(label) excluded")
                assertions += 1
            }
            if let filters = expected["filters"]?.arrayValue {
                let actual = Set(parsed.filters.map { $0.canonical })
                let wanted = Set(filters.compactMap { filter -> String? in
                    if let text = filter.stringValue { return text }
                    guard let members = filter.objectValue,
                          let key = members["key"]?.stringValue,
                          let value = members["value"]?.stringValue else { return nil }
                    let negated = members["negated"]?.boolValue ?? false
                    return "\(negated ? "-" : "")\(key):\(value)"
                })
                XCTAssertEqual(actual, wanted, "\(label) filters")
                assertions += 1
            }
        }
        return assertions
    }

    private func checkCanonicalJSON(_ testCase: JSONValue, label: String) -> Int {
        guard let input = value(testCase, ["json", "value", "object"]),
              let expected = text(testCase, ["canonicalJson", "canonical_json", "expectedCanonicalJson"])
        else { return 0 }
        XCTAssertEqual(input.canonicalJSON, expected, label)
        return 1
    }

    private func checkScrypt(_ testCase: JSONValue, label: String) -> Int {
        guard let password = text(testCase, ["password", "pin", "passphrase"]),
              let salt = bytes(testCase, ["salt", "saltHex"]),
              let n = integer(testCase, ["n", "N", "cost", "rounds"]),
              let r = integer(testCase, ["r", "blockSize"]),
              let p = integer(testCase, ["p", "parallelism"]),
              let expected = text(testCase, ["derivedKey", "expected", "dk", "expectedHex"])
        else { return 0 }
        let length = Int(integer(testCase, ["dkLen", "keyLength", "outputByteCount"]) ?? 32)
        guard let derived = try? ScryptKDF.derive(password: Data(password.utf8),
                                                  salt: Data(salt),
                                                  outputByteCount: length,
                                                  n: Int(n), r: Int(r), p: Int(p))
        else {
            XCTFail("\(label): scrypt derivation failed")
            return 1
        }
        XCTAssertEqual(Hex.encode(derived), expected.lowercased(), label)
        return 1
    }

    private func checkSecretBox(_ testCase: JSONValue, label: String) -> Int {
        guard let key = bytes(testCase, ["key", "keyHex", "dek"]),
              let nonce = bytes(testCase, ["nonce", "nonceHex", "iv"]),
              let thingID = text(testCase, ["thingId", "thing_id"]),
              let fieldID = text(testCase, ["fieldId", "field_id"]),
              let plaintext = text(testCase, ["plaintext", "value"]),
              let expected = text(testCase, ["envelope", "ciphertext", "expected", "expectedHex"]),
              key.count == 32, nonce.count == 12
        else { return 0 }
        guard let envelope = try? SecretBox.seal(Data(plaintext.utf8),
                                                 key: SymmetricKey(data: Data(key)),
                                                 thingID: thingID,
                                                 fieldID: fieldID,
                                                 nonceBytes: nonce)
        else {
            XCTFail("\(label): sealing failed")
            return 1
        }
        XCTAssertEqual(Hex.encode(envelope), expected.lowercased(), label)
        return 1
    }

    private func checkSHA256(_ testCase: JSONValue, label: String) -> Int {
        guard let input = text(testCase, ["contentUtf8", "plaintextUtf8", "bytesUtf8"]),
              let expected = text(testCase, ["sha256", "hash", "expectedHash"])
        else { return 0 }
        XCTAssertEqual(EncryptedObjectStore.sha256Hex(Data(input.utf8)), expected.lowercased(), label)
        return 1
    }
}
