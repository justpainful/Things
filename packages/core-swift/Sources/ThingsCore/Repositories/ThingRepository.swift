import Foundation
import GRDB

/// SQL fragments shared by every query that feeds a list of Things.
public enum ThingSQL {

    /// The dominant field variant, as an extra selected column named `dominant_variant`.
    ///
    /// Why this exists: `icon_json.type = 'auto'` resolves its SF Symbol from the Thing's
    /// fields, but the list queries fetch `thing` rows only. Without this column every
    /// automatic icon fell back to the generic `square.stack` and the whole library rendered
    /// as one glyph in twelve tints.
    ///
    /// A correlated subquery rather than a join, for two reasons: the row shape stays
    /// `thing.*` so nothing else has to change, and it is one statement rather than one
    /// query per row. `idx_field_thing(thing_id, sort_order)` covers the inner scan.
    ///
    /// **Deterministic by construction** — most frequent first, ties broken alphabetically —
    /// because the Screenshot Tour diffs pixels, and an icon that depended on row order
    /// would flag every screen on every run.
    ///
    /// The outer query must expose the table under the name `thing` for the correlation to
    /// resolve; every caller here either selects `FROM thing` or joins it unaliased.
    public static let dominantVariant = """
        (SELECT dv.variant FROM field AS dv
          WHERE dv.thing_id = thing.id AND dv.variant IS NOT NULL
          GROUP BY dv.variant
          ORDER BY count(*) DESC, dv.variant ASC
          LIMIT 1) AS dominant_variant
        """
}

/// A Thing with everything the detail screen needs, fetched in one pass.
public struct ThingDetail: Sendable, Equatable, Identifiable {
    public var thing: Thing
    public var sections: [ThingSection]
    public var fields: [Field]
    public var tags: [Tag]
    public var collections: [ThingCollection]
    /// Things whose `relation` fields point at this one — "Referenced by".
    public var backlinks: [Thing]
    /// Resolved file references for `path` and referenced-attachment fields.
    public var fileRefs: [String: FileRef]
    public var objects: [String: StoredObject]

    public var id: String { thing.id }

    public init(thing: Thing,
                sections: [ThingSection] = [],
                fields: [Field] = [],
                tags: [Tag] = [],
                collections: [ThingCollection] = [],
                backlinks: [Thing] = [],
                fileRefs: [String: FileRef] = [:],
                objects: [String: StoredObject] = [:]) {
        self.thing = thing
        self.sections = sections
        self.fields = fields
        self.tags = tags
        self.collections = collections
        self.backlinks = backlinks
        self.fileRefs = fileRefs
        self.objects = objects
    }

    public func fields(inSection sectionID: String?) -> [Field] {
        fields.filter { $0.sectionID == sectionID }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Fields whose variant is marked `gallery: true` in the registry, which is what the
    /// media gallery shows instead of a row.
    public func galleryFields(registry: FieldKindRegistry) -> [Field] {
        fields.filter { registry.variant($0.variant)?.showsInGallery == true }
    }
}

public struct ThingRepository: Sendable {

    let database: ThingsDatabase
    let oplog: Oplog

    public init(database: ThingsDatabase, oplog: Oplog) {
        self.database = database
        self.oplog = oplog
    }

    private var clock: ThingsClock { database.clock }
    private var registry: FieldKindRegistry { database.registry }

    // MARK: - Reads

    public static let recentLimit = 12
    public static let suggestionLimit = 6

    public func all(_ db: Database, limit: Int = 500) throws -> [Thing] {
        try Thing.fetchAll(
            db,
            sql: """
            SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
            WHERE deleted_at IS NULL AND is_template = 0 AND is_archived = 0
            ORDER BY title COLLATE NOCASE ASC
            LIMIT ?
            """,
            arguments: [limit]
        )
    }

    public func pinned(_ db: Database) throws -> [Thing] {
        try Thing.fetchAll(
            db,
            sql: """
            SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
            WHERE deleted_at IS NULL AND is_pinned = 1 AND is_template = 0
            ORDER BY updated_at DESC
            """
        )
    }

    public func recent(_ db: Database, limit: Int = ThingRepository.recentLimit) throws -> [Thing] {
        try Thing.fetchAll(
            db,
            sql: """
            SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
            WHERE deleted_at IS NULL AND is_template = 0
            ORDER BY COALESCE(viewed_at, updated_at) DESC
            LIMIT ?
            """,
            arguments: [limit]
        )
    }

    /// Home's "Suggestions": recently created but never opened. No model, no cloud — just
    /// the thing you made and forgot about.
    public func suggestions(_ db: Database, limit: Int = ThingRepository.suggestionLimit) throws -> [Thing] {
        try Thing.fetchAll(
            db,
            sql: """
            SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
            WHERE deleted_at IS NULL AND is_template = 0 AND viewed_at IS NULL
            ORDER BY created_at DESC
            LIMIT ?
            """,
            arguments: [limit]
        )
    }

    public func templates(_ db: Database) throws -> [Thing] {
        try Thing.fetchAll(db, sql: "SELECT * FROM thing WHERE is_template = 1 ORDER BY title COLLATE NOCASE")
    }

    public func trashed(_ db: Database) throws -> [Thing] {
        try Thing.fetchAll(db, sql: """
            SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
            WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC
            """)
    }

    /// Also the search-results path: `SearchService` returns hits, and the caller resolves
    /// each one through here — so the dominant variant has to be selected on this query too.
    public func find(_ db: Database, id: String) throws -> Thing? {
        try Thing.fetchOne(db, sql: """
            SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing WHERE id = ?
            """, arguments: [id])
    }

    public func detail(_ db: Database, id: String) throws -> ThingDetail? {
        guard let thing = try find(db, id: id) else { return nil }

        let sections = try ThingSection.fetchAll(
            db, sql: "SELECT * FROM section WHERE thing_id = ? ORDER BY sort_order", arguments: [id]
        )
        let fields = try Field.fetchAll(
            db, sql: "SELECT * FROM field WHERE thing_id = ? ORDER BY sort_order", arguments: [id]
        )
        let tags = try Tag.fetchAll(
            db,
            sql: """
            SELECT tag.* FROM tag
            JOIN thing_tag ON thing_tag.tag_id = tag.id
            WHERE thing_tag.thing_id = ? ORDER BY tag.name COLLATE NOCASE
            """,
            arguments: [id]
        )
        let collections = try ThingCollection.fetchAll(
            db,
            sql: """
            SELECT collection.* FROM collection
            JOIN collection_member ON collection_member.collection_id = collection.id
            WHERE collection_member.thing_id = ? ORDER BY collection.name COLLATE NOCASE
            """,
            arguments: [id]
        )
        // Backlinks are the relation index, never a second row.
        let backlinks = try Thing.fetchAll(
            db,
            sql: """
            SELECT DISTINCT thing.*, \(ThingSQL.dominantVariant) FROM thing
            JOIN field ON field.thing_id = thing.id
            WHERE field.kind = 'relation' AND field.value_text = ? AND thing.deleted_at IS NULL
            ORDER BY thing.title COLLATE NOCASE
            """,
            arguments: [id]
        )

        var fileRefs: [String: FileRef] = [:]
        let refIDs = fields.compactMap { $0.fileRefID }
        if !refIDs.isEmpty {
            let placeholders = refIDs.map { _ in "?" }.joined(separator: ", ")
            let rows = try FileRef.fetchAll(
                db,
                sql: "SELECT * FROM file_ref WHERE id IN (\(placeholders))",
                arguments: StatementArguments(refIDs)
            )
            for row in rows { fileRefs[row.id] = row }
        }

        var objects: [String: StoredObject] = [:]
        let hashes = fields.compactMap { $0.objectHash }
        if !hashes.isEmpty {
            let placeholders = hashes.map { _ in "?" }.joined(separator: ", ")
            let rows = try StoredObject.fetchAll(
                db,
                sql: "SELECT * FROM object WHERE hash IN (\(placeholders))",
                arguments: StatementArguments(hashes)
            )
            for row in rows { objects[row.objectHash] = row }
        }

        return ThingDetail(thing: thing,
                           sections: sections,
                           fields: fields,
                           tags: tags,
                           collections: collections,
                           backlinks: backlinks,
                           fileRefs: fileRefs,
                           objects: objects)
    }

    // MARK: - Writes

    @discardableResult
    public func create(_ db: Database,
                       title: String,
                       icon: ThingIcon = .automatic,
                       isPinned: Bool = false,
                       isLocked: Bool = false,
                       isTemplate: Bool = false) throws -> Thing {
        let now = clock.nowISO8601()
        let thing = Thing(
            id: UUIDv7.generate(clock: clock),
            title: title,
            iconJSON: icon.json,
            isPinned: isPinned,
            isLocked: isLocked,
            isTemplate: isTemplate,
            createdAt: now,
            updatedAt: now,
            versionVector: VersionVector().incrementing(database.deviceID).json
        )
        try thing.insert(db)
        try oplog.append(db, entityType: .thing, entityID: thing.id, op: .create,
                         attributes: try attributes(db, thingID: thing.id) ?? [:])
        try SearchIndexer.reindex(db, thingID: thing.id, index: database.search, registry: registry)
        return thing
    }

    /// Applies a patch to a Thing: bump the vector, write the row, append the oplog entry,
    /// reindex. Everything that mutates a Thing goes through here so none of those four
    /// steps can be forgotten in one place and not another.
    @discardableResult
    public func update(_ db: Database, id: String, patch: [String: JSONValue]) throws -> Thing? {
        guard var thing = try find(db, id: id) else { return nil }
        let previous = try attributes(db, thingID: id)

        var vector = thing.vector
        vector.increment(database.deviceID)

        var effective = patch
        effective["updated_at"] = .string(clock.nowISO8601())
        effective["version_vector"] = .string(vector.json)

        try EntityColumns.apply(db, entityType: .thing, entityID: id, attributes: effective, clock: clock)
        try oplog.append(db, entityType: .thing, entityID: id, op: .update,
                         attributes: effective, previous: previous)
        try SearchIndexer.reindex(db, thingID: id, index: database.search, registry: registry)

        thing = try find(db, id: id) ?? thing
        return thing
    }

    public func rename(_ db: Database, id: String, title: String) throws {
        try update(db, id: id, patch: ["title": .string(title)])
    }

    public func setPinned(_ db: Database, id: String, _ pinned: Bool) throws {
        try update(db, id: id, patch: ["is_pinned": .number(pinned ? 1 : 0)])
    }

    public func setLocked(_ db: Database, id: String, _ locked: Bool) throws {
        try update(db, id: id, patch: ["is_locked": .number(locked ? 1 : 0)])
    }

    public func setArchived(_ db: Database, id: String, _ archived: Bool) throws {
        try update(db, id: id, patch: ["is_archived": .number(archived ? 1 : 0)])
    }

    public func setIcon(_ db: Database, id: String, icon: ThingIcon) throws {
        try update(db, id: id, patch: ["icon_json": .string(icon.json)])
    }

    /// Recents ordering. Deliberately does **not** bump `updated_at` or the version vector:
    /// looking at something is not an edit, and treating it as one would fill the oplog with
    /// noise and manufacture sync traffic.
    public func markViewed(_ db: Database, id: String) throws {
        try db.execute(sql: "UPDATE thing SET viewed_at = ? WHERE id = ?",
                       arguments: [clock.nowISO8601(), id])
    }

    /// Soft delete → Recently Deleted.
    public func moveToTrash(_ db: Database, id: String) throws {
        try update(db, id: id, patch: ["deleted_at": .string(clock.nowISO8601())])
        try database.search.remove(db, thingID: id)
    }

    public func restoreFromTrash(_ db: Database, id: String) throws {
        try update(db, id: id, patch: ["deleted_at": .null])
    }

    /// Permanent. Cascades to sections and fields via the schema's foreign keys, and
    /// decrements object reference counts first so nothing is orphaned.
    public func deleteForever(_ db: Database, id: String) throws {
        let previous = try attributes(db, thingID: id)
        let hashes = try String.fetchAll(
            db,
            sql: "SELECT object_hash FROM field WHERE thing_id = ? AND object_hash IS NOT NULL",
            arguments: [id]
        )
        for hash in hashes {
            try db.execute(sql: "UPDATE object SET ref_count = MAX(0, ref_count - 1) WHERE hash = ?", arguments: [hash])
        }
        try db.execute(sql: "DELETE FROM field WHERE thing_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM thing WHERE id = ?", arguments: [id])
        try database.search.remove(db, thingID: id)
        try oplog.append(db, entityType: .thing, entityID: id, op: .delete,
                         attributes: [:], previous: previous)
    }

    public func emptyTrash(_ db: Database) throws {
        for thing in try trashed(db) {
            try deleteForever(db, id: thing.id)
        }
    }

    /// Retention sweep — anything in the trash older than the configured window.
    public func purgeExpiredTrash(_ db: Database) throws {
        let days = Int(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?",
                                           arguments: [MetaKey.trashRetentionDays]) ?? "30") ?? 30
        let cutoff = Timestamp.string(
            millisecondsSinceEpoch: clock.nowMilliseconds() - Int64(days) * Timestamp.millisecondsPerDay
        )
        let expired = try String.fetchAll(
            db,
            sql: "SELECT id FROM thing WHERE deleted_at IS NOT NULL AND deleted_at < ?",
            arguments: [cutoff]
        )
        for id in expired {
            try deleteForever(db, id: id)
        }
    }

    // MARK: - Duplication and templates

    /// "New from Template" — a deep copy of the sections and fields with empty values.
    @discardableResult
    public func createFromTemplate(_ db: Database,
                                   template: FieldKindRegistry.Template,
                                   title: String) throws -> Thing {
        let thing = try create(db, title: title, icon: ThingIcon(kind: .symbol, value: template.symbol))
        var sectionOrder = FractionalOrder.first
        for templateSection in template.sections {
            let sectionID: String?
            if let sectionTitle = templateSection.title, !sectionTitle.isEmpty {
                let section = ThingSection(
                    id: UUIDv7.generate(clock: clock),
                    thingID: thing.id,
                    title: sectionTitle,
                    sortOrder: sectionOrder,
                    createdAt: thing.createdAt,
                    updatedAt: thing.updatedAt,
                    versionVector: VersionVector().incrementing(database.deviceID).json
                )
                try section.insert(db)
                sectionID = section.id
                sectionOrder += FractionalOrder.step
            } else {
                sectionID = nil
            }

            var fieldOrder = FractionalOrder.first
            for templateField in templateSection.fields {
                guard let variant = registry.variant(templateField.variant) else { continue }
                let field = Field(
                    id: UUIDv7.generate(clock: clock),
                    thingID: thing.id,
                    sectionID: sectionID,
                    sortOrder: fieldOrder,
                    kind: variant.kind,
                    variant: variant.id,
                    label: templateField.label,
                    isSecret: registry.defaultIsSecret(forVariant: variant.id),
                    createdAt: thing.createdAt,
                    updatedAt: thing.updatedAt,
                    versionVector: VersionVector().incrementing(database.deviceID).json
                )
                try field.insert(db)
                fieldOrder += FractionalOrder.step
            }
        }
        try SearchIndexer.reindex(db, thingID: thing.id, index: database.search, registry: registry)
        return thing
    }

    @discardableResult
    public func duplicate(_ db: Database, id: String) throws -> Thing? {
        guard let detail = try detail(db, id: id) else { return nil }
        let copy = try create(db, title: detail.thing.title + " Copy",
                              icon: detail.thing.icon)

        var sectionMap: [String: String] = [:]
        for section in detail.sections {
            let newID = UUIDv7.generate(clock: clock)
            sectionMap[section.id] = newID
            var duplicated = section
            duplicated.id = newID
            duplicated.thingID = copy.id
            duplicated.versionVector = VersionVector().incrementing(database.deviceID).json
            try duplicated.insert(db)
        }
        for field in detail.fields {
            var duplicated = field
            duplicated.id = UUIDv7.generate(clock: clock)
            duplicated.thingID = copy.id
            duplicated.sectionID = field.sectionID.flatMap { sectionMap[$0] }
            duplicated.versionVector = VersionVector().incrementing(database.deviceID).json
            // A secret's AAD binds it to its original thing_id ‖ field_id, so the ciphertext
            // cannot be copied across. The duplicate gets the field, empty.
            if duplicated.valueCipher != nil {
                duplicated.valueCipher = nil
            }
            if let hash = duplicated.objectHash {
                try db.execute(sql: "UPDATE object SET ref_count = ref_count + 1 WHERE hash = ?", arguments: [hash])
            }
            try duplicated.insert(db)
        }
        try SearchIndexer.reindex(db, thingID: copy.id, index: database.search, registry: registry)
        return try find(db, id: copy.id)
    }

    // MARK: - Helpers

    func attributes(_ db: Database, thingID: String) throws -> [String: JSONValue]? {
        try EntityColumns.snapshot(db, entityType: .thing, entityID: thingID)
    }

    // MARK: - Live queries

    public func observeHome() -> AsyncThrowingStream<HomeSnapshot, Error> {
        LiveQuery.stream(in: database.queue) { db in
            HomeSnapshot(
                pinned: try Thing.fetchAll(db, sql: """
                    SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
                    WHERE deleted_at IS NULL AND is_pinned = 1 AND is_template = 0
                    ORDER BY updated_at DESC
                    """),
                recent: try Thing.fetchAll(db, sql: """
                    SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
                    WHERE deleted_at IS NULL AND is_template = 0
                    ORDER BY COALESCE(viewed_at, updated_at) DESC LIMIT \(ThingRepository.recentLimit)
                    """),
                // `is_smart` first, so the user's OWN collections come before the seeded
                // Smart Views. The smart views are installed at first launch and therefore
                // hold the lowest sort_order, which meant Home's five-collection shelf was
                // five smart views and none of 1980 / Development / Gaming — the user's
                // organisation was invisible on the screen built to surface it.
                collections: try ThingCollection.fetchAll(db, sql: """
                    SELECT * FROM collection WHERE parent_id IS NULL
                    ORDER BY is_smart, sort_order
                    """),
                suggestions: try Thing.fetchAll(db, sql: """
                    SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
                    WHERE deleted_at IS NULL AND is_template = 0 AND viewed_at IS NULL
                    ORDER BY created_at DESC LIMIT \(ThingRepository.suggestionLimit)
                    """),
                totalCount: try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM thing WHERE deleted_at IS NULL AND is_template = 0
                    """) ?? 0
            )
        }
    }

    public func observeAll() -> AsyncThrowingStream<[Thing], Error> {
        LiveQuery.stream(in: database.queue) { db in
            try Thing.fetchAll(db, sql: """
                SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
                WHERE deleted_at IS NULL AND is_template = 0 AND is_archived = 0
                ORDER BY title COLLATE NOCASE ASC
                """)
        }
    }

    public func observeTrash() -> AsyncThrowingStream<[Thing], Error> {
        LiveQuery.stream(in: database.queue) { db in
            try Thing.fetchAll(db, sql: """
                SELECT thing.*, \(ThingSQL.dominantVariant) FROM thing
                WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC
                """)
        }
    }

    public func observeDetail(id: String) -> AsyncThrowingStream<ThingDetail?, Error> {
        let repository = self
        return LiveQuery.stream(in: database.queue) { db in
            try repository.detail(db, id: id)
        }
    }
}

/// Everything Home shows, in one observed value — one query round trip per change rather
/// than five independent observations racing each other into different frames.
public struct HomeSnapshot: Sendable, Equatable {
    public var pinned: [Thing]
    public var recent: [Thing]
    public var collections: [ThingCollection]
    public var suggestions: [Thing]
    public var totalCount: Int

    public init(pinned: [Thing] = [], recent: [Thing] = [], collections: [ThingCollection] = [],
                suggestions: [Thing] = [], totalCount: Int = 0) {
        self.pinned = pinned
        self.recent = recent
        self.collections = collections
        self.suggestions = suggestions
        self.totalCount = totalCount
    }

    public static let empty = HomeSnapshot()
}
