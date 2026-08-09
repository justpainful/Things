import Foundation
import GRDB
import CryptoKit

/// The `object` table plus the encrypted bytes on disk.
///
/// Dedupe is the primary key: the hash is of the plaintext, so storing the same logo in
/// four Things costs one copy of the bytes and four reference counts.
public struct ObjectRepository: Sendable {

    let database: ThingsDatabase
    /// Named `blobStore`, not `store`, so it cannot collide with `store(_:data:…)`.
    public let blobStore: EncryptedObjectStore

    public init(database: ThingsDatabase, blobStore: EncryptedObjectStore) {
        self.database = database
        self.blobStore = blobStore
    }

    private var clock: ThingsClock { database.clock }

    public func find(_ db: Database, hash: String) throws -> StoredObject? {
        try StoredObject.fetchOne(db, sql: "SELECT * FROM object WHERE hash = ?", arguments: [hash])
    }

    /// - Returns: the row, and whether the bytes were already in the library.
    @discardableResult
    public func store(_ db: Database,
                      data: Data,
                      mimeType: String? = nil,
                      width: Int? = nil,
                      height: Int? = nil,
                      durationMs: Int? = nil) throws -> (object: StoredObject, wasDuplicate: Bool) {
        let hash = EncryptedObjectStore.sha256Hex(data)
        if let existing = try find(db, hash: hash) {
            return (existing, true)
        }
        // No row owns these bytes, so any file already on disk is an orphan from a crash.
        let receipt = try blobStore.store(data, replacingExisting: true)
        let object = StoredObject(
            objectHash: receipt.hash,
            byteSize: receipt.byteSize,
            mimeType: mimeType,
            width: width,
            height: height,
            durationMs: durationMs,
            encKeyWrap: receipt.encKeyWrap,
            encNonce: receipt.encNonce,
            refCount: 0,
            createdAt: clock.nowISO8601()
        )
        try object.insert(db)
        return (object, false)
    }

    public func load(_ db: Database, hash: String) throws -> Data {
        guard let object = try find(db, hash: hash) else {
            throw ThingsError.objectNotFound(hash)
        }
        return try blobStore.load(hash: hash, encKeyWrap: object.encKeyWrap)
    }

    public func isPresentOnDisk(hash: String) -> Bool {
        blobStore.exists(hash: hash)
    }

    /// Objects nobody references. Deleting them is the only place bytes actually go away.
    public func orphans(_ db: Database) throws -> [StoredObject] {
        try StoredObject.fetchAll(db, sql: "SELECT * FROM object WHERE ref_count <= 0 ORDER BY byte_size DESC")
    }

    public func collectGarbage(_ db: Database) throws -> Int {
        let orphaned = try orphans(db)
        for object in orphaned {
            try blobStore.delete(hash: object.objectHash)
            try db.execute(sql: "DELETE FROM object WHERE hash = ?", arguments: [object.objectHash])
        }
        return orphaned.count
    }

    /// Recomputes `ref_count` from the fields that actually point at each object. Cheap
    /// insurance against a drift bug turning into deleted user data.
    public func recomputeReferenceCounts(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE object SET ref_count = (
              SELECT count(*) FROM field WHERE field.object_hash = object.hash
            )
            """)
    }

    public func totalBytes(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_size), 0) FROM object") ?? 0
    }
}

/// Device-aware paths. `D:\Servers\BeamNG\Server1` is meaningless without knowing which
/// machine, so the device id is part of the reference rather than a note in the value.
public struct FileRefRepository: Sendable {

    let database: ThingsDatabase

    public init(database: ThingsDatabase) {
        self.database = database
    }

    private var clock: ThingsClock { database.clock }

    public func find(_ db: Database, id: String) throws -> FileRef? {
        try FileRef.fetchOne(db, sql: "SELECT * FROM file_ref WHERE id = ?", arguments: [id])
    }

    @discardableResult
    public func create(_ db: Database,
                       deviceID: String,
                       path: String,
                       isDirectory: Bool,
                       sizeAtLink: Int64? = nil,
                       status: FileRef.Status = .unknown) throws -> FileRef {
        let ref = FileRef(
            id: UUIDv7.generate(clock: clock),
            deviceID: deviceID,
            path: path,
            isDirectory: isDirectory,
            sizeAtLink: sizeAtLink,
            status: status,
            createdAt: clock.nowISO8601()
        )
        try ref.insert(db)
        return ref
    }

    public func setStatus(_ db: Database, id: String, status: FileRef.Status) throws {
        let seenAt: String? = status == .present ? clock.nowISO8601() : nil
        try db.execute(
            sql: "UPDATE file_ref SET status = ?, last_seen_at = ? WHERE id = ?",
            arguments: [status.rawValue, seenAt, id]
        )
    }

    public func missing(_ db: Database) throws -> [FileRef] {
        try FileRef.fetchAll(db, sql: "SELECT * FROM file_ref WHERE status = 'missing' ORDER BY path")
    }

    /// Only refs owned by *this* device can be checked; anything else stays `unknown`,
    /// which is why the UI says "on RAEID-PC" instead of "missing".
    public func refreshLocalStatus(_ db: Database) throws {
        let refs = try FileRef.fetchAll(db, sql: "SELECT * FROM file_ref WHERE device_id = ?",
                                        arguments: [database.deviceID])
        for ref in refs {
            let exists = FileManager.default.fileExists(atPath: ref.path)
            try setStatus(db, id: ref.id, status: exists ? .present : .missing)
        }
    }

    public func devices(_ db: Database) throws -> [Device] {
        try Device.fetchAll(db, sql: "SELECT * FROM device ORDER BY is_self DESC, name")
    }
}
