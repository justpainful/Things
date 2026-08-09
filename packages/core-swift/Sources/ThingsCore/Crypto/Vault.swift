import Foundation
import GRDB
import CryptoKit

/// Where the DEK wrappers live.
///
/// `spec/schema.sql` lists `dek_wrap_pin`, `dek_wrap_device`, `kdf_salt` and `kdf_params` as
/// seeded rows of the `meta` table, and `docs/01-DATA-MODEL.md` §7 says SQLCipher's key *is*
/// the DEK. Those two statements cannot both hold: you would need the DEK to open the
/// database that tells you how to unwrap the DEK.
///
/// `spec/crypto.md` §4 settles it: the wrappers live in a small **unencrypted sidecar** next
/// to the database (`vault.json`), and that file is normative. It contains only salts,
/// KDF parameters and AES-GCM-wrapped key material — useless without either the PIN or the
/// device, which is exactly the T1 threat model: copying the folder yields nothing. The
/// `meta` rows are still mirrored once the library is open, for a future backup format, and
/// are never read as the source of truth.
public protocol VaultStorage: Sendable {
    func value(forKey key: String) throws -> String?
    func setValue(_ value: String?, forKey key: String) throws
}

/// The real one: a JSON file beside the database.
public struct FileVaultStorage: VaultStorage {

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func value(forKey key: String) throws -> String? {
        try load()[key]
    }

    public func setValue(_ value: String?, forKey key: String) throws {
        var contents = try load()
        if let value {
            contents[key] = value
        } else {
            contents.removeValue(forKey: key)
        }
        var members: [String: JSONValue] = [:]
        for (key, value) in contents {
            members[key] = .string(value)
        }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(JSONValue.object(members).canonicalJSON.utf8).write(to: url, options: .atomic)
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let parsed = try? JSONValue.parse(data), let members = parsed.objectValue else { return [:] }
        var contents: [String: String] = [:]
        for (key, value) in members {
            if let text = value.stringValue { contents[key] = text }
        }
        return contents
    }
}

/// The `meta`-table mirror. Used once the library is open, so both the sidecar and the
/// database agree.
public struct DatabaseVaultStorage: VaultStorage {

    private let database: ThingsDatabase

    public init(database: ThingsDatabase) {
        self.database = database
    }

    public func value(forKey key: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public func setValue(_ value: String?, forKey key: String) throws {
        try database.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            }
        }
    }
}

/// Wraps and unwraps the DEK.
///
/// Order of operations at first run:
///   1. generate a random DEK
///   2. wrap it with the PIN-derived KEK      → `dek_wrap_pin`
///   3. wrap it with the device-derived KEK₂  → `dek_wrap_device`
///
/// Either wrapper opens the library on its own. That redundancy is the whole design: a
/// changed Apple ID, a sideloader that rewrites the bundle id, or a re-enrolled Face ID all
/// destroy the device wrapper, and only the PIN wrapper stands between that and a library
/// that opens empty.
public struct Vault: Sendable {

    public enum UnlockMethod: String, Sendable {
        case pin
        case device
    }

    public struct State: Sendable, Equatable {
        public var hasPINWrapper: Bool
        public var hasDeviceWrapper: Bool
        public var parameters: KDFParameters
        public var failedAttempts: Int

        public var isInitialised: Bool { hasPINWrapper }
        public var lockoutSeconds: Int { KeyHierarchy.lockoutSeconds(afterFailedAttempts: failedAttempts) }
    }

    public let storage: VaultStorage
    public let deviceKeyStore: DeviceKeyStore
    public let clock: ThingsClock

    public init(storage: VaultStorage,
                deviceKeyStore: DeviceKeyStore = DeviceKeyStore(),
                clock: ThingsClock = SystemClock.shared) {
        self.storage = storage
        self.deviceKeyStore = deviceKeyStore
        self.clock = clock
    }

    // MARK: - State

    public func state() throws -> State {
        State(
            hasPINWrapper: try storage.value(forKey: MetaKey.dekWrapPIN) != nil,
            hasDeviceWrapper: try storage.value(forKey: MetaKey.dekWrapDevice) != nil,
            parameters: KDFParameters.parse(try storage.value(forKey: MetaKey.kdfParams)),
            failedAttempts: Int(try storage.value(forKey: MetaKey.failedPINAttempts) ?? "0") ?? 0
        )
    }

    // MARK: - Setup

    /// First run. Creates the DEK and both wrappers.
    @discardableResult
    public func initialise(pin: String,
                           dek: SymmetricKey? = nil,
                           parameters: KDFParameters = .recommended) throws -> SymmetricKey {
        let key = dek ?? KeyHierarchy.generateDEK(clock: clock)
        // One salt. `spec/crypto.md` §3: the device KEK's HKDF salt *is* the KDF salt, which
        // is why rotating it (changePIN) also re-wraps for the device.
        let salt = KeyHierarchy.generateSalt(clock: clock)

        let pinKEK = try KeyHierarchy.deriveKEK(pin: pin, salt: salt, parameters: parameters)
        let pinWrap = try KeyHierarchy.wrap(key, with: pinKEK, context: KeyHierarchy.Context.pinWrap)

        try storage.setValue(salt.base64EncodedString(), forKey: MetaKey.kdfSalt)
        try storage.setValue(parameters.json, forKey: MetaKey.kdfParams)
        try storage.setValue(pinWrap.base64EncodedString(), forKey: MetaKey.dekWrapPIN)
        try storage.setValue("0", forKey: MetaKey.failedPINAttempts)

        try wrapForDevice(key, salt: salt)
        return key
    }

    /// Best effort. A device without a usable enclave — or a keychain a free Personal Team
    /// cannot reach — still has a fully working library through the PIN, so a failure here
    /// removes the device wrapper rather than failing the operation. A wrapper left behind
    /// under a stale salt would never open again.
    private func wrapForDevice(_ dek: SymmetricKey, salt: Data) throws {
        guard let deviceKEK = try? deviceKeyStore.deriveKEK(salt: salt),
              let wrap = try? KeyHierarchy.wrap(dek, with: deviceKEK, context: KeyHierarchy.Context.deviceWrap)
        else {
            try storage.setValue(nil, forKey: MetaKey.dekWrapDevice)
            return
        }
        try storage.setValue(wrap.base64EncodedString(), forKey: MetaKey.dekWrapDevice)
    }

    // MARK: - Unlock

    public func unlockWithPIN(_ pin: String) throws -> SymmetricKey {
        guard let wrapText = try storage.value(forKey: MetaKey.dekWrapPIN),
              let wrap = Data(base64Encoded: wrapText),
              let saltText = try storage.value(forKey: MetaKey.kdfSalt),
              let salt = Data(base64Encoded: saltText)
        else { throw ThingsError.cryptoFailure("this library has no PIN wrapper") }

        let parameters = KDFParameters.parse(try storage.value(forKey: MetaKey.kdfParams))
        let kek = try KeyHierarchy.deriveKEK(pin: pin, salt: salt, parameters: parameters)
        do {
            let dek = try KeyHierarchy.unwrap(wrap, with: kek, context: KeyHierarchy.Context.pinWrap)
            try storage.setValue("0", forKey: MetaKey.failedPINAttempts)
            return dek
        } catch {
            let attempts = (Int(try storage.value(forKey: MetaKey.failedPINAttempts) ?? "0") ?? 0) + 1
            try storage.setValue(String(attempts), forKey: MetaKey.failedPINAttempts)
            throw error
        }
    }

    public func unlockWithDevice() throws -> SymmetricKey {
        guard let wrapText = try storage.value(forKey: MetaKey.dekWrapDevice),
              let wrap = Data(base64Encoded: wrapText),
              let saltText = try storage.value(forKey: MetaKey.kdfSalt),
              let salt = Data(base64Encoded: saltText)
        else { throw ThingsError.cryptoFailure("this library has no device wrapper") }

        let kek = try deviceKeyStore.deriveKEK(salt: salt)
        return try KeyHierarchy.unwrap(wrap, with: kek, context: KeyHierarchy.Context.deviceWrap)
    }

    /// Changing the PIN re-wraps 32 bytes. It never re-encrypts the library.
    public func changePIN(current: String, new: String) throws {
        let dek = try unlockWithPIN(current)
        let parameters = KDFParameters.parse(try storage.value(forKey: MetaKey.kdfParams))
        let salt = KeyHierarchy.generateSalt(clock: clock)
        let kek = try KeyHierarchy.deriveKEK(pin: new, salt: salt, parameters: parameters)
        let wrap = try KeyHierarchy.wrap(dek, with: kek, context: KeyHierarchy.Context.pinWrap)
        try storage.setValue(salt.base64EncodedString(), forKey: MetaKey.kdfSalt)
        try storage.setValue(wrap.base64EncodedString(), forKey: MetaKey.dekWrapPIN)
        // The device KEK is salted with this same value, so it has to be rebuilt here or the
        // device wrapper silently stops opening.
        try wrapForDevice(dek, salt: salt)
    }

    /// Re-creates the device wrapper — the repair path after Face ID is re-enrolled.
    public func refreshDeviceWrapper(dek: SymmetricKey) throws {
        guard let saltText = try storage.value(forKey: MetaKey.kdfSalt),
              let salt = Data(base64Encoded: saltText)
        else { throw ThingsError.cryptoFailure("this library has no KDF salt") }
        let kek = try deviceKeyStore.deriveKEK(salt: salt)
        let wrap = try KeyHierarchy.wrap(dek, with: kek, context: KeyHierarchy.Context.deviceWrap)
        try storage.setValue(wrap.base64EncodedString(), forKey: MetaKey.dekWrapDevice)
    }

    public func removeDeviceWrapper() throws {
        try storage.setValue(nil, forKey: MetaKey.dekWrapDevice)
        try? deviceKeyStore.reset()
    }

    /// Copies the wrapper material into the library's own `meta` table once it is open, so
    /// the database carries a record of its own key hierarchy for a future backup format.
    public func mirrorIntoDatabase(_ database: ThingsDatabase) throws {
        let mirror = DatabaseVaultStorage(database: database)
        for key in [MetaKey.kdfSalt, MetaKey.kdfParams, MetaKey.dekWrapPIN,
                    MetaKey.dekWrapDevice] {
            try mirror.setValue(try storage.value(forKey: key), forKey: key)
        }
    }
}
