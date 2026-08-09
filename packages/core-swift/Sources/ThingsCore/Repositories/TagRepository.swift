import Foundation
import GRDB

public struct TagRepository: Sendable {

    let database: ThingsDatabase
    let oplog: Oplog

    public init(database: ThingsDatabase, oplog: Oplog) {
        self.database = database
        self.oplog = oplog
    }

    private var clock: ThingsClock { database.clock }

    public func all(_ db: Database) throws -> [Tag] {
        try Tag.fetchAll(db, sql: "SELECT * FROM tag ORDER BY name COLLATE NOCASE")
    }

    public func tags(_ db: Database, forThing thingID: String) throws -> [Tag] {
        try Tag.fetchAll(
            db,
            sql: """
            SELECT tag.* FROM tag
            JOIN thing_tag ON thing_tag.tag_id = tag.id
            WHERE thing_tag.thing_id = ? ORDER BY tag.name COLLATE NOCASE
            """,
            arguments: [thingID]
        )
    }

    /// Tag names are unique case-insensitively, so "1980" and "1980" never become two tags.
    @discardableResult
    public func findOrCreate(_ db: Database, name: String, color: String? = nil) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try Tag.fetchOne(db, sql: "SELECT * FROM tag WHERE name = ? COLLATE NOCASE", arguments: [trimmed]) {
            return existing
        }
        let tag = Tag(id: UUIDv7.generate(clock: clock), name: trimmed, color: color, createdAt: clock.nowISO8601())
        try tag.insert(db)
        try oplog.append(db, entityType: .tag, entityID: tag.id, op: .create,
                         attributes: EntityColumns.snapshot(db, entityType: .tag, entityID: tag.id) ?? [:])
        return tag
    }

    public func attach(_ db: Database, tagName: String, to thingID: String) throws {
        let tag = try findOrCreate(db, name: tagName)
        try db.execute(
            sql: "INSERT INTO thing_tag (thing_id, tag_id) VALUES (?, ?) ON CONFLICT(thing_id, tag_id) DO NOTHING",
            arguments: [thingID, tag.id]
        )
        try oplog.append(db, entityType: .thingTag, entityID: "\(thingID)/\(tag.id)", op: .create,
                         attributes: ["thing_id": .string(thingID), "tag_id": .string(tag.id)])
        try SearchIndexer.reindex(db, thingID: thingID, index: database.search, registry: database.registry)
    }

    public func detach(_ db: Database, tagID: String, from thingID: String) throws {
        try db.execute(sql: "DELETE FROM thing_tag WHERE thing_id = ? AND tag_id = ?", arguments: [thingID, tagID])
        try oplog.append(db, entityType: .thingTag, entityID: "\(thingID)/\(tagID)", op: .delete,
                         attributes: [:],
                         previous: ["thing_id": .string(thingID), "tag_id": .string(tagID)])
        try SearchIndexer.reindex(db, thingID: thingID, index: database.search, registry: database.registry)
    }

    /// Tags nobody uses any more, so the tag picker does not silt up.
    public func pruneOrphans(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM tag WHERE id NOT IN (SELECT tag_id FROM thing_tag)")
    }
}
