import Foundation
import GRDB

/// The oplog. One table, four features: History, Restore, Undo, and sync.
///
/// Materialised rows are the fold; `change` is the truth of *change*. Secret values inside
/// `attrs_json`/`prev_json` are stored as base64 of the AES-GCM envelope, never plaintext —
/// otherwise History becomes a plaintext log of every password ever changed, which is an
/// easy and severe mistake to make.
public struct Oplog: Sendable {

    public let deviceID: String
    public let clock: ThingsClock
    private let hlc: HLCGenerator

    public init(deviceID: String, hlc: HLCGenerator, clock: ThingsClock) {
        self.deviceID = deviceID
        self.hlc = hlc
        self.clock = clock
    }

    // MARK: - Writing

    @discardableResult
    public func append(_ db: Database,
                       entityType: EntityType,
                       entityID: String,
                       op: ChangeOperation,
                       attributes: [String: JSONValue],
                       previous: [String: JSONValue]? = nil) throws -> Change {
        let stamp = hlc.next()
        let change = Change(
            id: UUIDv7.generate(clock: clock),
            deviceID: deviceID,
            hlc: stamp.description,
            entityType: entityType,
            entityID: entityID,
            op: op,
            attrsJSON: JSONValue.object(attributes).canonicalJSON,
            prevJSON: previous.map { JSONValue.object($0).canonicalJSON },
            appliedAt: clock.nowISO8601()
        )
        try change.insert(db)
        return change
    }

    /// Records a change that arrived from a peer, folding its stamp into our clock.
    @discardableResult
    public func appendReceived(_ db: Database, remote: Change) throws -> Change {
        if let stamp = remote.stamp {
            _ = hlc.receive(stamp)
        }
        var stored = remote
        stored.appliedAt = clock.nowISO8601()
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO change
              (id, device_id, hlc, entity_type, entity_id, op, attrs_json, prev_json, applied_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [stored.id, stored.deviceID, stored.hlc, stored.entityType,
                        stored.entityID, stored.op, stored.attrsJSON, stored.prevJSON, stored.appliedAt]
        )
        return stored
    }

    // MARK: - Reading

    /// Everything that ever happened to a Thing, newest first — the Thing's own row plus
    /// its sections and fields, which is what "Today · Changed password" needs.
    public func history(_ db: Database, thingID: String, limit: Int = 500) throws -> [Change] {
        try Change.fetchAll(
            db,
            sql: """
            SELECT * FROM change
            WHERE entity_id = ?
               OR entity_id IN (SELECT id FROM section WHERE thing_id = ?)
               OR entity_id IN (SELECT id FROM field   WHERE thing_id = ?)
            ORDER BY hlc DESC
            LIMIT ?
            """,
            arguments: [thingID, thingID, thingID, limit]
        )
    }

    public func changes(_ db: Database, forEntity entityID: String, limit: Int = 200) throws -> [Change] {
        try Change.fetchAll(
            db,
            sql: "SELECT * FROM change WHERE entity_id = ? ORDER BY hlc DESC LIMIT ?",
            arguments: [entityID, limit]
        )
    }

    /// "Send me everything after HLC x" — the sync read path.
    public func changes(_ db: Database, after stamp: HLC?, limit: Int = 1000) throws -> [Change] {
        if let stamp {
            return try Change.fetchAll(
                db,
                sql: "SELECT * FROM change WHERE hlc > ? ORDER BY hlc ASC LIMIT ?",
                arguments: [stamp.description, limit]
            )
        }
        return try Change.fetchAll(db, sql: "SELECT * FROM change ORDER BY hlc ASC LIMIT ?", arguments: [limit])
    }

    // MARK: - Restore and undo

    /// Restores the entity to the state recorded in a change's `prev_json`.
    ///
    /// Never destructive: the restore is itself appended to the oplog, so restoring is
    /// part of history rather than a hole in it.
    @discardableResult
    public func restore(_ db: Database, changeID: String) throws -> Change {
        guard let change = try Change.fetchOne(db, sql: "SELECT * FROM change WHERE id = ?", arguments: [changeID]) else {
            throw ThingsError.entityNotFound(entity: "change", id: changeID)
        }
        guard let entityType = change.entity else {
            throw ThingsError.unsupportedEntityType(change.entityType)
        }
        guard let previous = change.previous?.objectValue else {
            throw ThingsError.entityNotFound(entity: "previous value of change", id: changeID)
        }

        let current = try EntityColumns.snapshot(db, entityType: entityType, entityID: change.entityID)
        try EntityColumns.apply(db, entityType: entityType, entityID: change.entityID, attributes: previous, clock: clock)

        return try append(db,
                          entityType: entityType,
                          entityID: change.entityID,
                          op: .update,
                          attributes: previous,
                          previous: current)
    }

    /// The inverse of a single change — the Undo primitive.
    @discardableResult
    public func undo(_ db: Database, changeID: String) throws -> Change {
        guard let change = try Change.fetchOne(db, sql: "SELECT * FROM change WHERE id = ?", arguments: [changeID]) else {
            throw ThingsError.entityNotFound(entity: "change", id: changeID)
        }
        guard let entityType = change.entity, let operation = change.operation else {
            throw ThingsError.unsupportedEntityType(change.entityType)
        }

        switch operation {
        case .create:
            let current = try EntityColumns.snapshot(db, entityType: entityType, entityID: change.entityID)
            try db.execute(sql: "DELETE FROM \(entityType.tableName) WHERE id = ?", arguments: [change.entityID])
            return try append(db, entityType: entityType, entityID: change.entityID,
                              op: .delete, attributes: [:], previous: current)
        case .update:
            return try restore(db, changeID: changeID)
        case .delete:
            guard let previous = change.previous?.objectValue else {
                throw ThingsError.entityNotFound(entity: "previous value of change", id: changeID)
            }
            try EntityColumns.insert(db, entityType: entityType, entityID: change.entityID, attributes: previous, clock: clock)
            return try append(db, entityType: entityType, entityID: change.entityID,
                              op: .create, attributes: previous, previous: nil)
        }
    }

    // MARK: - Retention

    /// Keeps `days` of detail, then collapses everything older to a single snapshot per
    /// entity. Default 90 days.
    public func compact(_ db: Database, keepingDays days: Int = 90) throws {
        let cutoffMillis = clock.nowMilliseconds() - Int64(days) * Timestamp.millisecondsPerDay
        let cutoff = Timestamp.string(millisecondsSinceEpoch: cutoffMillis)
        try db.execute(
            sql: """
            DELETE FROM change
            WHERE applied_at < ?
              AND id NOT IN (
                SELECT id FROM (
                  SELECT id, ROW_NUMBER() OVER (PARTITION BY entity_id ORDER BY hlc DESC) AS position
                  FROM change WHERE applied_at < ?
                ) WHERE position = 1
              )
            """,
            arguments: [cutoff, cutoff]
        )
    }
}

/// A bounded, in-memory stack of change ids for session Undo/Redo.
public final class UndoStack: @unchecked Sendable {

    private let lock = NSLock()
    private var undoable: [String] = []
    private var redoable: [String] = []
    private let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = capacity
    }

    public func record(_ changeID: String) {
        lock.lock()
        defer { lock.unlock() }
        undoable.append(changeID)
        if undoable.count > capacity { undoable.removeFirst() }
        redoable.removeAll()
    }

    public func popUndo() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = undoable.popLast() else { return nil }
        redoable.append(last)
        return last
    }

    public func popRedo() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = redoable.popLast() else { return nil }
        undoable.append(last)
        return last
    }

    public var canUndo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !undoable.isEmpty
    }

    public var canRedo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !redoable.isEmpty
    }

    public func clear() {
        lock.lock()
        undoable.removeAll()
        redoable.removeAll()
        lock.unlock()
    }
}
