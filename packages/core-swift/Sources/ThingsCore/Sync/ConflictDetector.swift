import Foundation
import GRDB

/// Version-vector merge.
///
/// The rule, in full:
///
/// | Comparison            | Meaning         | Action     |
/// |-----------------------|-----------------|------------|
/// | local dominates remote| we saw it       | keep local |
/// | remote dominates local| they saw ours   | apply remote |
/// | equal                 | same history    | no-op      |
/// | neither               | concurrent      | **conflict** |
///
/// Because vectors live on **fields**, the case that matters resolves the way it should:
/// the phone edits Notes while the PC edits Password → two different entities → both apply,
/// no conflict. Only a genuine same-field collision surfaces "2 Versions", and the higher
/// HLC is shown provisionally so the app stays usable while the choice is pending.
public struct ConflictDetector: Sendable {

    public enum Resolution: String, Sendable {
        case keepLocal
        case applyRemote
        case noChange
        case conflict
    }

    public let clock: ThingsClock

    public init(clock: ThingsClock) {
        self.clock = clock
    }

    public static func resolution(local: VersionVector, remote: VersionVector) -> Resolution {
        switch local.compare(to: remote) {
        case .equal: return .noChange
        case .dominates: return .keepLocal
        case .dominated: return .applyRemote
        case .concurrent: return .conflict
        }
    }

    /// Records an open conflict and returns its id.
    @discardableResult
    public func record(_ db: Database,
                       entityType: EntityType,
                       entityID: String,
                       local: [String: JSONValue],
                       remote: [String: JSONValue]) throws -> String {
        // One open conflict per entity. A second concurrent edit updates the pair rather
        // than stacking a third card in the UI.
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT id FROM conflict WHERE entity_id = ? AND resolved_at IS NULL LIMIT 1",
            arguments: [entityID]
        ) {
            try db.execute(
                sql: "UPDATE conflict SET version_a_json = ?, version_b_json = ?, detected_at = ? WHERE id = ?",
                arguments: [JSONValue.object(local).canonicalJSON,
                            JSONValue.object(remote).canonicalJSON,
                            clock.nowISO8601(),
                            existing]
            )
            return existing
        }

        let conflict = Conflict(
            id: UUIDv7.generate(clock: clock),
            entityType: entityType.rawValue,
            entityID: entityID,
            versionAJSON: JSONValue.object(local).canonicalJSON,
            versionBJSON: JSONValue.object(remote).canonicalJSON,
            detectedAt: clock.nowISO8601()
        )
        try conflict.insert(db)
        return conflict.id
    }

    public func openConflicts(_ db: Database) throws -> [Conflict] {
        try Conflict.fetchAll(db, sql: "SELECT * FROM conflict WHERE resolved_at IS NULL ORDER BY detected_at DESC")
    }

    public func openConflict(_ db: Database, entityID: String) throws -> Conflict? {
        try Conflict.fetchOne(
            db,
            sql: "SELECT * FROM conflict WHERE entity_id = ? AND resolved_at IS NULL LIMIT 1",
            arguments: [entityID]
        )
    }

    /// Applies the user's choice from the "2 Versions" sheet.
    public func resolve(_ db: Database,
                        conflictID: String,
                        choosing side: ConflictSide,
                        oplog: Oplog) throws {
        guard let conflict = try Conflict.fetchOne(db, sql: "SELECT * FROM conflict WHERE id = ?", arguments: [conflictID]) else {
            throw ThingsError.entityNotFound(entity: "conflict", id: conflictID)
        }
        guard let entityType = EntityType(rawValue: conflict.entityType) else {
            throw ThingsError.unsupportedEntityType(conflict.entityType)
        }

        let chosenJSON = side == .a ? conflict.versionAJSON : conflict.versionBJSON
        if side != .both, let attributes = (try? JSONValue.parse(chosenJSON))?.objectValue {
            let previous = try EntityColumns.snapshot(db, entityType: entityType, entityID: conflict.entityID)
            try EntityColumns.apply(db, entityType: entityType, entityID: conflict.entityID,
                                    attributes: attributes, clock: clock)
            try oplog.append(db, entityType: entityType, entityID: conflict.entityID,
                             op: .update, attributes: attributes, previous: previous)
        }

        try db.execute(
            sql: "UPDATE conflict SET resolved_at = ?, resolution = ? WHERE id = ?",
            arguments: [clock.nowISO8601(), side.rawValue, conflictID]
        )
    }
}

public enum ConflictSide: String, Sendable {
    /// The local version.
    case a
    /// The version that arrived from the peer.
    case b
    /// Keep both — the caller is expected to have already duplicated the entity.
    case both
    case manual
}
