import Foundation
import CryptoKit
import Security

/// The device half of the key hierarchy.
///
/// The Secure Enclave holds **P-256 keys only** and cannot store a symmetric key at all.
/// So the pattern is: SE `P256.KeyAgreement.PrivateKey` → `sharedSecretFromKeyAgreement`
/// with its own public key → `hkdfDerivedSymmetricKey` → KEK₂. Same key material every
/// time, and the private half never leaves the enclave.
///
/// ⚠️ **The simulator has no Secure Enclave.** Apple's DTS is explicit that it "acts like
/// an iOS device that has no SE". Every screenshot in this project is taken on a simulator,
/// so the software fallback below is not a nicety — without it the app cannot be run in CI
/// at all.
///
/// The key's `dataRepresentation` (an SE-encrypted blob, not the key) is persisted as
/// `kSecClassGenericPassword` with **no `kSecAttrAccessGroup`**. That lands the item in the
/// default group `$(teamID).$(bundleID)`, granted by the implicit `application-identifier`
/// entitlement even a free Personal Team carries. Setting an explicit group would need the
/// Keychain Sharing capability, which a free account cannot mint.
public final class DeviceKeyStore: @unchecked Sendable {

    public enum Backing: String, Sendable {
        /// Real Secure Enclave key, gated by Face ID.
        case secureEnclave
        /// Software P-256 key in the keychain. Simulator, or a device without an SE.
        case software
    }

    private let service: String
    private let account: String
    private let lock = NSLock()

    public init(service: String = "com.things.app.devicekey", account: String = "dek-wrapper-v1") {
        self.service = service
        self.account = account
    }

    /// Whether a real enclave is available here. `false` in the simulator, always.
    public static var isSecureEnclaveAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return SecureEnclave.isAvailable
        #endif
    }

    public var backing: Backing {
        DeviceKeyStore.isSecureEnclaveAvailable ? .secureEnclave : .software
    }

    /// Derives the device KEK, creating and persisting the underlying key on first use.
    ///
    /// - Parameter salt: stored in `meta`, alongside the PIN salt.
    public func deriveKEK(salt: Data, info: String = KeyHierarchy.Context.deviceAgreement) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }

        #if targetEnvironment(simulator)
        return try softwareKEK(salt: salt, info: info)
        #else
        if SecureEnclave.isAvailable {
            return try enclaveKEK(salt: salt, info: info)
        }
        return try softwareKEK(salt: salt, info: info)
        #endif
    }

    /// Removes the device wrapper. The PIN wrapper is untouched, which is exactly why the
    /// PIN path has to exist.
    public func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        try deleteStoredBlob()
    }

    // MARK: - Secure Enclave path

    #if !targetEnvironment(simulator)
    private func enclaveKEK(salt: Data, info: String) throws -> SymmetricKey {
        let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        if let blob = try loadStoredBlob() {
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        } else {
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                [.privateKeyUsage, .biometryCurrentSet],
                &accessError
            ) else {
                let code = accessError.map { CFErrorGetCode($0.takeRetainedValue()) } ?? -1
                throw ThingsError.keychainFailure(status: Int32(code), operation: "SecAccessControlCreateWithFlags")
            }
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            try storeBlob(privateKey.dataRepresentation)
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: privateKey.publicKey)
        return KeyHierarchy.deriveKEK(fromSharedSecret: shared, salt: salt, info: info)
    }
    #endif

    // MARK: - Software fallback

    private func softwareKEK(salt: Data, info: String) throws -> SymmetricKey {
        let privateKey: P256.KeyAgreement.PrivateKey
        if let blob = try loadStoredBlob() {
            privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: blob)
        } else {
            privateKey = P256.KeyAgreement.PrivateKey()
            try storeBlob(privateKey.rawRepresentation)
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: privateKey.publicKey)
        return KeyHierarchy.deriveKEK(fromSharedSecret: shared, salt: salt, info: info)
    }

    // MARK: - Keychain

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
            // Deliberately NO kSecAttrAccessGroup. See the type comment.
        ]
    }

    private func loadStoredBlob() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw ThingsError.keychainFailure(status: status, operation: "read")
        }
    }

    private func storeBlob(_ data: Data) throws {
        try deleteStoredBlob()
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ThingsError.keychainFailure(status: status, operation: "write")
        }
    }

    private func deleteStoredBlob() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ThingsError.keychainFailure(status: status, operation: "delete")
        }
    }
}
