import Foundation
import GRDB
import CryptoKit

/// The open library.
///
/// Owns exactly one GRDB `DatabaseQueue` — a single connection, which is the right shape
/// for a single-process phone app and removes a whole class of SQLCipher-plus-pool
/// questions we cannot test locally.
public final class ThingsDatabase: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// `nil` means an in-memory database (tests).
        public var path: String?
        /// The DEK. `nil` opens the database unencrypted — only ever used by unit tests
        /// that are exercising SQL rather than crypto.
        public var key: SymmetricKey?
        public var deviceID: String
        public var deviceName: String
        public var platform: String
        public var readOnly: Bool

        public init(path: String?,
                    key: SymmetricKey?,
                    deviceID: String,
                    deviceName: String,
                    platform: String = "ios",
                    readOnly: Bool = false) {
            self.path = path
            self.key = key
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.platform = platform
            self.readOnly = readOnly
        }
    }

    public let queue: DatabaseQueue
    public let diagnostics: SQLiteDiagnostics
    public let registry: FieldKindRegistry
    public let clock: ThingsClock
    public let deviceID: String
    public let hlc: HLCGenerator
    public let search: SearchIndex

    private init(queue: DatabaseQueue,
                 diagnostics: SQLiteDiagnostics,
                 registry: FieldKindRegistry,
                 clock: ThingsClock,
                 deviceID: String,
                 hlc: HLCGenerator,
                 search: SearchIndex) {
        self.queue = queue
        self.diagnostics = diagnostics
        self.registry = registry
        self.clock = clock
        self.deviceID = deviceID
        self.hlc = hlc
        self.search = search
    }

    // MARK: - Opening

    public static func open(_ configuration: Configuration,
                            clock: ThingsClock = SystemClock.shared,
                            registry: FieldKindRegistry? = nil) throws -> ThingsDatabase {

        let loadedRegistry = try registry ?? FieldKindRegistry.loadBundled()

        var grdbConfiguration = GRDB.Configuration()
        grdbConfiguration.foreignKeysEnabled = true
        grdbConfiguration.readonly = configuration.readOnly
        if let key = configuration.key {
            let rawKey = KeyHierarchy.sqlcipherRawKey(key)
            grdbConfiguration.prepareDatabase { db in
                // Raw key form, so SQLCipher does not run its own KDF over a key that has
                // already been through scrypt. Must be the first statement on the
                // connection.
                try db.execute(sql: "PRAGMA key = \"x'\(rawKey)'\"")
            }
        }

        let queue: DatabaseQueue
        if let path = configuration.path {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            queue = try DatabaseQueue(path: path, configuration: grdbConfiguration)
        } else {
            queue = try DatabaseQueue(configuration: grdbConfiguration)
        }

        // Outside a transaction: `journal_mode` cannot be changed inside one, and the FTS5
        // probe has to be allowed to fail without rolling anything back.
        let diagnostics: SQLiteDiagnostics = try queue.writeWithoutTransaction { db -> SQLiteDiagnostics in
            if configuration.key != nil {
                // Fails loudly and immediately if the key is wrong, instead of at the first
                // real query with a confusing "file is not a database".
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
            }
            if configuration.path != nil && !configuration.readOnly {
                try? db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            return SQLiteDiagnostics.probe(db, isEncrypted: configuration.key != nil)
        }

        let search: SearchIndex = diagnostics.hasFTS5 ? FTS5SearchIndex() : LikeSearchIndex()

        if !configuration.readOnly {
            try queue.write { db in
                try createSchemaIfNeeded(db, hasFTS5: diagnostics.hasFTS5)
                try seedLocalState(db, configuration: configuration, clock: clock)
            }
        }

        let lastHLC: HLC? = try queue.read { db -> HLC? in
            let text = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [MetaKey.hlcLast])
            guard let text else { return nil }
            return HLC.parse(text)
        }

        return ThingsDatabase(
            queue: queue,
            diagnostics: diagnostics,
            registry: loadedRegistry,
            clock: clock,
            deviceID: configuration.deviceID,
            hlc: HLCGenerator(deviceID: configuration.deviceID, clock: clock, resumingFrom: lastHLC),
            search: search
        )
    }

    // MARK: - Schema

    static func createSchemaIfNeeded(_ db: Database, hasFTS5: Bool) throws {
        let alreadyThere = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'thing')"
        ) ?? false
        if alreadyThere {
            // The fallback table is created lazily so a library made on a build *with* FTS5
            // still opens on a build without it.
            if !hasFTS5 {
                try db.execute(sql: SchemaSQL.fallbackSearchTableSQL)
            }
            return
        }

        let sql = try SchemaSQL.bundledText()
        for statement in SchemaSQL.statements(in: sql) {
            if SchemaSQL.isPragma(statement) { continue }
            if SchemaSQL.isFTS5VirtualTable(statement) {
                if hasFTS5 {
                    try db.execute(sql: statement)
                } else {
                    try db.execute(sql: SchemaSQL.fallbackSearchTableSQL)
                }
                continue
            }
            do {
                try db.execute(sql: statement)
            } catch {
                throw ThingsError.schemaLoadFailed("\(error) — while running: \(statement.prefix(120))")
            }
        }
        if !hasFTS5 {
            try db.execute(sql: SchemaSQL.fallbackSearchTableSQL)
        }
    }

    static func seedLocalState(_ db: Database, configuration: Configuration, clock: ThingsClock) throws {
        let now = clock.nowISO8601()

        try db.execute(
            sql: "INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)",
            arguments: [MetaKey.schemaVersion, String(ThingsCoreInfo.schemaVersion)]
        )
        try db.execute(
            sql: "INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)",
            arguments: [MetaKey.deviceID, configuration.deviceID]
        )
        try db.execute(
            sql: "INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)",
            arguments: [MetaKey.trashRetentionDays, "30"]
        )
        try db.execute(
            sql: """
            INSERT INTO device (id, name, platform, is_self, last_seen_at)
            VALUES (?, ?, ?, 1, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, last_seen_at = excluded.last_seen_at
            """,
            arguments: [configuration.deviceID, configuration.deviceName, configuration.platform, now]
        )
    }

    // MARK: - Housekeeping

    /// Persists the clock so a restart cannot re-issue a stamp it already used.
    public func persistClock() throws {
        let stamp = hlc.current.description
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [MetaKey.hlcLast, stamp]
            )
        }
    }

    public func close() {
        try? persistClock()
    }

    // MARK: - Convenience

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.write(block)
    }
}

/// Rows of the `meta` table. Local, never synced.
public enum MetaKey {
    public static let schemaVersion = "schema_version"
    public static let dekWrapPIN = "dek_wrap_pin"
    public static let dekWrapDevice = "dek_wrap_device"
    public static let kdfParams = "kdf_params"
    public static let kdfSalt = "kdf_salt"
    /// Legacy. The device KEK is now salted with `kdf_salt`, per `spec/crypto.md` §3, so
    /// nothing writes this key any more. Kept so an older sidecar still parses.
    public static let deviceSalt = "device_salt"
    public static let deviceID = "device_id"
    public static let hlcLast = "hlc_last"
    public static let trashRetentionDays = "trash_retention_days"
    public static let seedMarker = "seed_marker"
    public static let autoLockSeconds = "auto_lock_seconds"
    public static let failedPINAttempts = "failed_pin_attempts"
}

public enum ThingsCoreInfo {
    public static let schemaVersion = 1
    public static let version = "1.0.0"
    /// Written into `meta` by seed data and asserted before any screenshot is taken. There
    /// is no code path from a real library to a CI artifact.
    public static let seedMarkerValue = "THINGS-FICTIONAL-SEED-DO-NOT-SHIP"
}
