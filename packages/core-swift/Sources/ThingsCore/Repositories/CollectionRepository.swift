import Foundation
import GRDB

public struct CollectionContents: Sendable, Equatable {
    public var collection: ThingCollection?
    public var things: [Thing]

    public init(collection: ThingCollection?, things: [Thing]) {
        self.collection = collection
        self.things = things
    }
}

public struct CollectionSummary: Sendable, Equatable, Identifiable {
    public var collection: ThingCollection
    public var count: Int
    public var id: String { collection.id }

    public init(collection: ThingCollection, count: Int) {
        self.collection = collection
        self.count = count
    }
}

/// Collections are many-to-many, which is what lets one Thing live in both `Development`
/// and `1980` without a second copy of the data.
///
/// A Saved Search is not a separate concept: it is `collection(is_smart = 1,
/// smart_query = '…')`. Smart Views ship as seeded smart collections, so the user can edit
/// them and build their own.
public struct CollectionRepository: Sendable {

    let database: ThingsDatabase
    let oplog: Oplog

    public init(database: ThingsDatabase, oplog: Oplog) {
        self.database = database
        self.oplog = oplog
    }

    private var clock: ThingsClock { database.clock }

    // MARK: - Reads

    public func all(_ db: Database) throws -> [ThingCollection] {
        try ThingCollection.fetchAll(db, sql: "SELECT * FROM collection ORDER BY sort_order, name COLLATE NOCASE")
    }

    public func topLevel(_ db: Database) throws -> [ThingCollection] {
        try ThingCollection.fetchAll(db, sql: "SELECT * FROM collection WHERE parent_id IS NULL ORDER BY sort_order")
    }

    public func children(_ db: Database, of parentID: String) throws -> [ThingCollection] {
        try ThingCollection.fetchAll(db, sql: "SELECT * FROM collection WHERE parent_id = ? ORDER BY sort_order",
                                     arguments: [parentID])
    }

    public func find(_ db: Database, id: String) throws -> ThingCollection? {
        try ThingCollection.fetchOne(db, sql: "SELECT * FROM collection WHERE id = ?", arguments: [id])
    }

    /// Members of a normal collection, or the resolved query of a smart one.
    public func members(_ db: Database, collectionID: String, search: SearchService) throws -> [Thing] {
        guard let collection = try find(db, id: collectionID) else { return [] }
        if collection.isSmart, let query = collection.smartQuery {
            let hits = try search.search(db, query: SearchQuery.parse(query))
            guard !hits.isEmpty else { return [] }
            let ids = hits.map { $0.thingID }
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let things = try Thing.fetchAll(
                db,
                sql: "SELECT * FROM thing WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            var byID: [String: Thing] = [:]
            for thing in things { byID[thing.id] = thing }
            return ids.compactMap { byID[$0] }
        }
        return try Thing.fetchAll(
            db,
            sql: """
            SELECT thing.* FROM thing
            JOIN collection_member ON collection_member.thing_id = thing.id
            WHERE collection_member.collection_id = ? AND thing.deleted_at IS NULL
            ORDER BY collection_member.sort_order
            """,
            arguments: [collectionID]
        )
    }

    public func summaries(_ db: Database, search: SearchService) throws -> [CollectionSummary] {
        try topLevel(db).map { collection in
            let count: Int
            if collection.isSmart, let query = collection.smartQuery {
                count = try search.search(db, query: SearchQuery.parse(query)).count
            } else {
                count = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT count(*) FROM collection_member
                    JOIN thing ON thing.id = collection_member.thing_id
                    WHERE collection_member.collection_id = ? AND thing.deleted_at IS NULL
                    """,
                    arguments: [collection.id]
                ) ?? 0
            }
            return CollectionSummary(collection: collection, count: count)
        }
    }

    public func collectionIDs(_ db: Database, containing thingID: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT collection_id FROM collection_member WHERE thing_id = ?",
                            arguments: [thingID])
    }

    // MARK: - Writes

    @discardableResult
    public func create(_ db: Database,
                       name: String,
                       icon: ThingIcon = ThingIcon(kind: .symbol, value: "folder"),
                       parentID: String? = nil,
                       smartQuery: String? = nil,
                       isSystem: Bool = false) throws -> ThingCollection {
        let now = clock.nowISO8601()
        let existing = try all(db).map { $0.sortOrder }
        let collection = ThingCollection(
            id: UUIDv7.generate(clock: clock),
            name: name,
            iconJSON: icon.json,
            sortOrder: FractionalOrder.appending(after: existing),
            parentID: parentID,
            isSmart: smartQuery != nil,
            isSystem: isSystem,
            smartQuery: smartQuery,
            createdAt: now,
            updatedAt: now,
            versionVector: VersionVector().incrementing(database.deviceID).json
        )
        try collection.insert(db)
        try oplog.append(db, entityType: .collection, entityID: collection.id, op: .create,
                         attributes: EntityColumns.snapshot(db, entityType: .collection, entityID: collection.id) ?? [:])
        return collection
    }

    public func rename(_ db: Database, id: String, name: String) throws {
        try patch(db, id: id, patch: ["name": .string(name)])
    }

    public func setSmartQuery(_ db: Database, id: String, query: String?) throws {
        try patch(db, id: id, patch: [
            "smart_query": query.map { JSONValue.string($0) } ?? .null,
            "is_smart": .number(query == nil ? 0 : 1)
        ])
    }

    func patch(_ db: Database, id: String, patch: [String: JSONValue]) throws {
        guard let collection = try find(db, id: id) else { return }
        let previous = try EntityColumns.snapshot(db, entityType: .collection, entityID: id)
        var vector = VersionVector.parse(collection.versionVector)
        vector.increment(database.deviceID)
        var effective = patch
        effective["updated_at"] = .string(clock.nowISO8601())
        effective["version_vector"] = .string(vector.json)
        try EntityColumns.apply(db, entityType: .collection, entityID: id, attributes: effective, clock: clock)
        try oplog.append(db, entityType: .collection, entityID: id, op: .update,
                         attributes: effective, previous: previous)
    }

    public func delete(_ db: Database, id: String) throws {
        let previous = try EntityColumns.snapshot(db, entityType: .collection, entityID: id)
        try db.execute(sql: "DELETE FROM collection WHERE id = ?", arguments: [id])
        try oplog.append(db, entityType: .collection, entityID: id, op: .delete,
                         attributes: [:], previous: previous)
    }

    public func add(_ db: Database, thingID: String, to collectionID: String) throws {
        let orders = try Double.fetchAll(
            db, sql: "SELECT sort_order FROM collection_member WHERE collection_id = ?", arguments: [collectionID]
        )
        let member = CollectionMember(
            collectionID: collectionID,
            thingID: thingID,
            sortOrder: FractionalOrder.appending(after: orders),
            addedAt: clock.nowISO8601()
        )
        try db.execute(
            sql: """
            INSERT INTO collection_member (collection_id, thing_id, sort_order, added_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(collection_id, thing_id) DO NOTHING
            """,
            arguments: [member.collectionID, member.thingID, member.sortOrder, member.addedAt]
        )
        try oplog.append(db, entityType: .member, entityID: "\(collectionID)/\(thingID)", op: .create,
                         attributes: [
                            "collection_id": .string(collectionID),
                            "thing_id": .string(thingID),
                            "sort_order": .number(EntityColumns.canonicalDouble(member.sortOrder)),
                            "added_at": .string(member.addedAt)
                         ])
        try SearchIndexer.reindex(db, thingID: thingID, index: database.search, registry: database.registry)
    }

    public func remove(_ db: Database, thingID: String, from collectionID: String) throws {
        try db.execute(sql: "DELETE FROM collection_member WHERE collection_id = ? AND thing_id = ?",
                       arguments: [collectionID, thingID])
        try oplog.append(db, entityType: .member, entityID: "\(collectionID)/\(thingID)", op: .delete,
                         attributes: [:],
                         previous: ["collection_id": .string(collectionID), "thing_id": .string(thingID)])
        try SearchIndexer.reindex(db, thingID: thingID, index: database.search, registry: database.registry)
    }

    // MARK: - Live queries

    public func observeAll() -> AsyncThrowingStream<[ThingCollection], Error> {
        LiveQuery.stream(in: database.queue) { db in
            try ThingCollection.fetchAll(db, sql: "SELECT * FROM collection ORDER BY sort_order, name COLLATE NOCASE")
        }
    }

    /// Observes a collection's contents. Written as one fetch so GRDB tracks every table it
    /// reads — `collection`, `collection_member`, `thing`, and for a smart collection
    /// whatever the query touches. Observing `collection` alone would miss a membership
    /// change, which is the exact bug that makes a live list feel broken.
    public func observeMembers(collectionID: String, search: SearchService) -> AsyncThrowingStream<CollectionContents, Error> {
        let repository = self
        return LiveQuery.stream(in: database.queue) { db in
            CollectionContents(
                collection: try repository.find(db, id: collectionID),
                things: try repository.members(db, collectionID: collectionID, search: search)
            )
        }
    }

    public func observeSummaries(search: SearchService) -> AsyncThrowingStream<[CollectionSummary], Error> {
        let repository = self
        return LiveQuery.stream(in: database.queue) { db in
            try repository.summaries(db, search: search)
        }
    }
}
