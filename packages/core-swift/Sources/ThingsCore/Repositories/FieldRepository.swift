import Foundation
import GRDB
import CryptoKit

/// Sections and Fields.
///
/// Everything a Thing points at is a Field — relations, files, paths, tags included — which
/// is what makes ordering, sections, drag-and-drop and the Add Field flow uniform instead
/// of six special cases.
public struct FieldRepository: Sendable {

    let database: ThingsDatabase
    let oplog: Oplog

    public init(database: ThingsDatabase, oplog: Oplog) {
        self.database = database
        self.oplog = oplog
    }

    private var clock: ThingsClock { database.clock }
    private var registry: FieldKindRegistry { database.registry }

    // MARK: - Sections

    public func sections(_ db: Database, thingID: String) throws -> [ThingSection] {
        try ThingSection.fetchAll(db, sql: "SELECT * FROM section WHERE thing_id = ? ORDER BY sort_order",
                                  arguments: [thingID])
    }

    @discardableResult
    public func addSection(_ db: Database, thingID: String, title: String?) throws -> ThingSection {
        let existing = try sections(db, thingID: thingID).map { $0.sortOrder }
        let now = clock.nowISO8601()
        let section = ThingSection(
            id: UUIDv7.generate(clock: clock),
            thingID: thingID,
            title: title,
            sortOrder: FractionalOrder.appending(after: existing),
            createdAt: now,
            updatedAt: now,
            versionVector: VersionVector().incrementing(database.deviceID).json
        )
        try section.insert(db)
        try oplog.append(db, entityType: .section, entityID: section.id, op: .create,
                         attributes: EntityColumns.snapshot(db, entityType: .section, entityID: section.id) ?? [:])
        try touchThing(db, thingID: thingID)
        return section
    }

    public func renameSection(_ db: Database, sectionID: String, title: String?) throws {
        try patchSection(db, sectionID: sectionID, patch: ["title": title.map { JSONValue.string($0) } ?? .null])
    }

    public func deleteSection(_ db: Database, sectionID: String) throws {
        guard let section = try ThingSection.fetchOne(db, sql: "SELECT * FROM section WHERE id = ?", arguments: [sectionID]) else { return }
        let previous = try EntityColumns.snapshot(db, entityType: .section, entityID: sectionID)
        // Fields survive; the schema's ON DELETE SET NULL drops them into the unnamed
        // default section rather than deleting the user's data behind their back.
        try db.execute(sql: "DELETE FROM section WHERE id = ?", arguments: [sectionID])
        try oplog.append(db, entityType: .section, entityID: sectionID, op: .delete,
                         attributes: [:], previous: previous)
        try touchThing(db, thingID: section.thingID)
    }

    func patchSection(_ db: Database, sectionID: String, patch: [String: JSONValue]) throws {
        guard let section = try ThingSection.fetchOne(db, sql: "SELECT * FROM section WHERE id = ?", arguments: [sectionID]) else { return }
        let previous = try EntityColumns.snapshot(db, entityType: .section, entityID: sectionID)
        var vector = VersionVector.parse(section.versionVector)
        vector.increment(database.deviceID)
        var effective = patch
        effective["updated_at"] = .string(clock.nowISO8601())
        effective["version_vector"] = .string(vector.json)
        try EntityColumns.apply(db, entityType: .section, entityID: sectionID, attributes: effective, clock: clock)
        try oplog.append(db, entityType: .section, entityID: sectionID, op: .update,
                         attributes: effective, previous: previous)
        try touchThing(db, thingID: section.thingID)
    }

    // MARK: - Fields

    public func fields(_ db: Database, thingID: String) throws -> [Field] {
        try Field.fetchAll(db, sql: "SELECT * FROM field WHERE thing_id = ? ORDER BY sort_order",
                           arguments: [thingID])
    }

    public func find(_ db: Database, id: String) throws -> Field? {
        try Field.fetchOne(db, sql: "SELECT * FROM field WHERE id = ?", arguments: [id])
    }

    /// Adds a field from a registry variant. The kind, default secrecy and storage all come
    /// from `field-kinds.json` — nothing here knows what a "password" is.
    @discardableResult
    public func addField(_ db: Database,
                         thingID: String,
                         variantID: String,
                         label: String? = nil,
                         sectionID: String? = nil,
                         valueText: String? = nil,
                         valueJSON: String? = nil,
                         secretPlaintext: String? = nil,
                         dek: SymmetricKey? = nil,
                         objectHash: String? = nil,
                         fileRefID: String? = nil) throws -> Field {
        guard let variant = registry.variant(variantID) else {
            throw ThingsError.registryInvalid("no variant '\(variantID)'")
        }
        let existing = try fields(db, thingID: thingID).map { $0.sortOrder }
        let now = clock.nowISO8601()
        let fieldID = UUIDv7.generate(clock: clock)
        let isSecret = registry.defaultIsSecret(forVariant: variantID)

        var cipher: Data?
        if let secretPlaintext, !secretPlaintext.isEmpty {
            guard let dek else {
                throw ThingsError.cryptoFailure("a secret field needs the library key")
            }
            cipher = try SecretBox.sealString(secretPlaintext, key: dek, thingID: thingID, fieldID: fieldID)
        }

        let field = Field(
            id: fieldID,
            thingID: thingID,
            sectionID: sectionID,
            sortOrder: FractionalOrder.appending(after: existing),
            kind: variant.kind,
            variant: variant.id,
            label: label ?? variant.label,
            valueText: isSecret ? nil : valueText,
            valueJSON: isSecret ? nil : valueJSON,
            valueCipher: cipher,
            objectHash: objectHash,
            fileRefID: fileRefID,
            isSecret: isSecret,
            createdAt: now,
            updatedAt: now,
            versionVector: VersionVector().incrementing(database.deviceID).json
        )
        try field.validateValueCarrier()
        try field.insert(db)
        if let objectHash {
            try db.execute(sql: "UPDATE object SET ref_count = ref_count + 1 WHERE hash = ?", arguments: [objectHash])
        }
        try oplog.append(db, entityType: .field, entityID: fieldID, op: .create,
                         attributes: EntityColumns.snapshot(db, entityType: .field, entityID: fieldID) ?? [:])
        try touchThing(db, thingID: thingID)
        return field
    }

    /// The generic patch path — used by every field edit so the vector bump, oplog append
    /// and reindex cannot be skipped by accident.
    public func patchField(_ db: Database, fieldID: String, patch: [String: JSONValue]) throws {
        guard let field = try find(db, id: fieldID) else { return }
        let previous = try EntityColumns.snapshot(db, entityType: .field, entityID: fieldID)
        var vector = field.vector
        vector.increment(database.deviceID)
        var effective = patch
        effective["updated_at"] = .string(clock.nowISO8601())
        effective["version_vector"] = .string(vector.json)
        try EntityColumns.apply(db, entityType: .field, entityID: fieldID, attributes: effective, clock: clock)
        try oplog.append(db, entityType: .field, entityID: fieldID, op: .update,
                         attributes: effective, previous: previous)
        try touchThing(db, thingID: field.thingID)
    }

    public func setText(_ db: Database, fieldID: String, _ value: String?) throws {
        try patchField(db, fieldID: fieldID, patch: ["value_text": value.map { JSONValue.string($0) } ?? .null])
    }

    public func setJSON(_ db: Database, fieldID: String, _ value: String?) throws {
        try patchField(db, fieldID: fieldID, patch: ["value_json": value.map { JSONValue.string($0) } ?? .null])
    }

    public func setLabel(_ db: Database, fieldID: String, _ label: String) throws {
        try patchField(db, fieldID: fieldID, patch: ["label": .string(label)])
    }

    /// Writes a secret. The AAD binds the ciphertext to `thing_id ‖ field_id`, and the
    /// oplog gets the *envelope*, base64'd — never the plaintext.
    public func setSecret(_ db: Database, fieldID: String, plaintext: String, dek: SymmetricKey) throws {
        guard let field = try find(db, id: fieldID) else { return }
        let envelope = try SecretBox.sealString(plaintext, key: dek, thingID: field.thingID, fieldID: fieldID)
        try patchField(db, fieldID: fieldID, patch: [
            "value_cipher": EntityColumns.blobJSON(envelope),
            "value_text": .null,
            "value_json": .null,
            "is_secret": .number(1)
        ])
    }

    public func revealSecret(_ db: Database, fieldID: String, dek: SymmetricKey) throws -> String {
        guard let field = try find(db, id: fieldID) else {
            throw ThingsError.entityNotFound(entity: "field", id: fieldID)
        }
        guard let cipher = field.valueCipher else { return "" }
        return try SecretBox.openString(cipher, key: dek, thingID: field.thingID, fieldID: fieldID)
    }

    public func deleteField(_ db: Database, fieldID: String) throws {
        guard let field = try find(db, id: fieldID) else { return }
        let previous = try EntityColumns.snapshot(db, entityType: .field, entityID: fieldID)
        if let hash = field.objectHash {
            try db.execute(sql: "UPDATE object SET ref_count = MAX(0, ref_count - 1) WHERE hash = ?", arguments: [hash])
        }
        try db.execute(sql: "DELETE FROM field WHERE id = ?", arguments: [fieldID])
        try oplog.append(db, entityType: .field, entityID: fieldID, op: .delete,
                         attributes: [:], previous: previous)
        try touchThing(db, thingID: field.thingID)
    }

    // MARK: - Ordering

    /// Fractional move: one row changes, not forty.
    public func move(_ db: Database, fieldID: String, toSection sectionID: String?, after: Field?, before: Field?) throws {
        let order = FractionalOrder.between(after?.sortOrder, before?.sortOrder)
        try patchField(db, fieldID: fieldID, patch: [
            "sort_order": .number(EntityColumns.canonicalDouble(order)),
            "section_id": sectionID.map { JSONValue.string($0) } ?? .null
        ])
        try rebalanceIfNeeded(db, thingID: try find(db, id: fieldID)?.thingID ?? "")
    }

    func rebalanceIfNeeded(_ db: Database, thingID: String) throws {
        guard !thingID.isEmpty else { return }
        let existing = try fields(db, thingID: thingID)
        guard FractionalOrder.needsRebalance(existing.map { $0.sortOrder }) else { return }
        let orders = FractionalOrder.rebalanced(count: existing.count)
        for (index, field) in existing.sorted(by: { $0.sortOrder < $1.sortOrder }).enumerated() {
            try db.execute(sql: "UPDATE field SET sort_order = ? WHERE id = ?",
                           arguments: [orders[index], field.id])
        }
    }

    // MARK: - Duplicate detection

    /// "This link already exists in GitHub Project." Uses the partial index on
    /// `field(value_text) WHERE kind='url'`.
    public func thingsContaining(_ db: Database, url: String, excluding thingID: String? = nil) throws -> [Thing] {
        try Thing.fetchAll(
            db,
            sql: """
            SELECT DISTINCT thing.* FROM thing
            JOIN field ON field.thing_id = thing.id
            WHERE field.kind = 'url' AND field.value_text = ?
              AND thing.deleted_at IS NULL AND thing.id IS NOT ?
            ORDER BY thing.title COLLATE NOCASE
            """,
            arguments: [url, thingID]
        )
    }

    // MARK: - Helpers

    func touchThing(_ db: Database, thingID: String) throws {
        try db.execute(sql: "UPDATE thing SET updated_at = ? WHERE id = ?",
                       arguments: [clock.nowISO8601(), thingID])
        try SearchIndexer.reindex(db, thingID: thingID, index: database.search, registry: registry)
    }
}
