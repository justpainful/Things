import Foundation
import GRDB
import CryptoKit

/// The one object the app holds.
///
/// Composes the open database, the oplog, the repositories, the object store and search.
/// Nothing above this line needs to know GRDB exists.
public final class Library: @unchecked Sendable {

    public let database: ThingsDatabase
    public let oplog: Oplog
    public let things: ThingRepository
    public let fields: FieldRepository
    public let collections: CollectionRepository
    public let tags: TagRepository
    public let objects: ObjectRepository
    public let fileRefs: FileRefRepository
    public let search: SearchService
    public let conflicts: ConflictDetector
    public let undo = UndoStack()

    /// Held for the lifetime of the unlocked session. Dropping the `Library` drops it.
    public let dek: SymmetricKey

    public var registry: FieldKindRegistry { database.registry }
    public var clock: ThingsClock { database.clock }
    public var diagnostics: SQLiteDiagnostics { database.diagnostics }
    public var deviceID: String { database.deviceID }

    public init(database: ThingsDatabase, dek: SymmetricKey, objectsDirectory: URL) {
        self.database = database
        self.dek = dek
        let oplog = Oplog(deviceID: database.deviceID, hlc: database.hlc, clock: database.clock)
        self.oplog = oplog
        self.things = ThingRepository(database: database, oplog: oplog)
        self.fields = FieldRepository(database: database, oplog: oplog)
        self.collections = CollectionRepository(database: database, oplog: oplog)
        self.tags = TagRepository(database: database, oplog: oplog)
        self.objects = ObjectRepository(
            database: database,
            blobStore: EncryptedObjectStore(rootDirectory: objectsDirectory, dek: dek, clock: database.clock)
        )
        self.fileRefs = FileRefRepository(database: database)
        self.search = SearchService(index: database.search, registry: database.registry, clock: database.clock)
        self.conflicts = ConflictDetector(clock: database.clock)
    }

    // MARK: - Standard file layout

    public struct Locations: Sendable {
        public var root: URL
        public var databasePath: String { root.appendingPathComponent("things.sqlite").path }
        public var objectsDirectory: URL { root.appendingPathComponent("objects", isDirectory: true) }
        public var vaultURL: URL { root.appendingPathComponent("vault.json") }

        public init(root: URL) {
            self.root = root
        }

        /// `Application Support/Things/` — outside `Documents`, so file sharing cannot
        /// expose the raw database even with `UIFileSharingEnabled` on.
        public static func standard() throws -> Locations {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
            let root = support.appendingPathComponent("Things", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return Locations(root: root)
        }

        public func prepare() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: objectsDirectory, withIntermediateDirectories: true)
        }
    }

    /// Opens an existing library, or creates one, given an already-unwrapped DEK.
    public static func open(locations: Locations,
                            dek: SymmetricKey,
                            deviceID: String,
                            deviceName: String,
                            platform: String = "ios",
                            clock: ThingsClock = SystemClock.shared) throws -> Library {
        try locations.prepare()
        let database = try ThingsDatabase.open(
            ThingsDatabase.Configuration(
                path: locations.databasePath,
                key: dek,
                deviceID: deviceID,
                deviceName: deviceName,
                platform: platform
            ),
            clock: clock
        )
        return Library(database: database, dek: dek, objectsDirectory: locations.objectsDirectory)
    }

    // MARK: - Convenience passthroughs

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try database.read(block)
    }

    @discardableResult
    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try database.write(block)
    }

    /// The current state of one row as oplog JSON. Public so callers outside the package —
    /// seed data, an eventual sync client — can build a conflict pair without reaching into
    /// the column allow-list themselves.
    public func snapshot(_ db: Database, entityType: EntityType, entityID: String) throws -> [String: JSONValue]? {
        try EntityColumns.snapshot(db, entityType: entityType, entityID: entityID)
    }

    /// Everything a first run needs: the seeded smart collections from the registry.
    public func installSmartViewsIfNeeded() throws {
        try write { db in
            let existing = try String.fetchAll(db, sql: "SELECT name FROM collection WHERE is_system = 1")
            let existingNames = Set(existing)
            for view in registry.smartViews where !existingNames.contains(view.name) {
                try collections.create(
                    db,
                    name: view.name,
                    icon: ThingIcon(kind: .symbol, value: view.symbol),
                    smartQuery: view.query,
                    isSystem: true
                )
            }
        }
    }

    public func rebuildSearchIndex() throws {
        try write { db in
            try SearchIndexer.rebuildAll(db, index: database.search, registry: registry)
        }
    }

    /// Trash retention + orphaned objects + orphaned tags, in one pass. Called at launch.
    public func runMaintenance() throws {
        try write { db in
            try things.purgeExpiredTrash(db)
            try objects.recomputeReferenceCounts(db)
            try tags.pruneOrphans(db)
        }
    }

    public func close() {
        database.close()
    }
}
