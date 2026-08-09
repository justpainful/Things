import Foundation
import GRDB

/// Builds the indexed document for one Thing.
public enum SearchIndexer {

    /// - Returns: `nil` when the Thing must not be indexed at all — deleted, or locked.
    ///   Locked Things contribute nothing to search, Recents previews, or the app-switcher
    ///   snapshot while locked.
    public static func document(_ db: Database,
                                thingID: String,
                                registry: FieldKindRegistry) throws -> SearchDocument? {
        guard let thing = try Thing.fetchOne(db, sql: "SELECT * FROM thing WHERE id = ?", arguments: [thingID]) else {
            return nil
        }
        if thing.deletedAt != nil || thing.isLocked { return nil }

        var document = SearchDocument(thingID: thingID)
        document.title = thing.title

        var labels: [String] = []
        var values: [String] = []
        var notes: [String] = []
        var urls: [String] = []
        var filenames: [String] = []
        var markers: Set<String> = []

        let fields = try Field.fetchAll(
            db,
            sql: "SELECT * FROM field WHERE thing_id = ? ORDER BY sort_order",
            arguments: [thingID]
        )

        for field in fields {
            labels.append(field.label)
            if let variant = registry.variant(field.variant), let marker = variant.marker {
                markers.insert(FieldKindRegistry.indexToken(forMarker: marker))
            }

            if field.isSecret || field.kind == .secret {
                // Label only. Never the value. This is the whole point.
                continue
            }

            switch field.kind {
            case .url:
                if let value = field.valueText {
                    urls.append(value)
                    markers.insert("hasurl")
                }
            case .richText, .longText:
                if let value = field.valueText { notes.append(value) }
                if let value = field.valueJSON { notes.append(SearchIndexer.plainText(fromRichTextJSON: value)) }
            case .attachment:
                if let name = field.filename { filenames.append(name) }
                markers.insert("hasfile")
            case .path:
                markers.insert("haspath")
            case .relation, .tagList:
                break
            default:
                if let value = field.valueText { values.append(value) }
                if let value = field.valueJSON { values.append(SearchIndexer.plainText(fromJSON: value)) }
            }
        }

        let tagNames = try String.fetchAll(
            db,
            sql: """
            SELECT tag.name FROM tag
            JOIN thing_tag ON thing_tag.tag_id = tag.id
            WHERE thing_tag.thing_id = ?
            ORDER BY tag.name
            """,
            arguments: [thingID]
        )
        if !tagNames.isEmpty { markers.insert("hastag") }

        let collectionNames = try String.fetchAll(
            db,
            sql: """
            SELECT collection.name FROM collection
            JOIN collection_member ON collection_member.collection_id = collection.id
            WHERE collection_member.thing_id = ?
            ORDER BY collection.name
            """,
            arguments: [thingID]
        )

        let pathValues = try String.fetchAll(
            db,
            sql: """
            SELECT file_ref.path FROM file_ref
            JOIN field ON field.file_ref_id = file_ref.id
            WHERE field.thing_id = ?
            """,
            arguments: [thingID]
        )
        let missingCount = try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM file_ref
            JOIN field ON field.file_ref_id = file_ref.id
            WHERE field.thing_id = ? AND file_ref.status = 'missing'
            """,
            arguments: [thingID]
        ) ?? 0
        if missingCount > 0 { markers.insert("ismissing") }
        if thing.isPinned { markers.insert("ispinned") }

        document.labels = labels.joined(separator: " ")
        document.values = values.joined(separator: " ")
        document.notes = notes.joined(separator: " ")
        document.tags = tagNames.joined(separator: " ")
        document.urls = urls.joined(separator: " ")
        document.paths = pathValues.joined(separator: " ")
        document.filenames = filenames.joined(separator: " ")
        document.collections = collectionNames.joined(separator: " ")
        document.markers = markers.sorted().joined(separator: " ")
        return document
    }

    /// Re-indexes one Thing, removing it if it is no longer indexable.
    public static func reindex(_ db: Database,
                               thingID: String,
                               index: SearchIndex,
                               registry: FieldKindRegistry) throws {
        if let document = try document(db, thingID: thingID, registry: registry) {
            try index.upsert(db, document: document)
        } else {
            try index.remove(db, thingID: thingID)
        }
    }

    public static func rebuildAll(_ db: Database, index: SearchIndex, registry: FieldKindRegistry) throws {
        try index.removeAll(db)
        let ids = try String.fetchAll(db, sql: "SELECT id FROM thing WHERE deleted_at IS NULL AND is_locked = 0")
        for id in ids {
            if let document = try document(db, thingID: id, registry: registry) {
                try index.upsert(db, document: document)
            }
        }
    }

    // MARK: - Flattening

    /// Pulls readable text out of the portable rich-text tree. The tree format is deferred
    /// to `spec/richtext.md` (M4), so this walks generically: every `text` string anywhere
    /// in the structure is indexed, and everything else is ignored.
    public static func plainText(fromRichTextJSON json: String) -> String {
        guard let value = try? JSONValue.parse(json) else { return "" }
        var pieces: [String] = []
        collectText(value, into: &pieces)
        return pieces.joined(separator: " ")
    }

    public static func plainText(fromJSON json: String) -> String {
        guard let value = try? JSONValue.parse(json) else { return "" }
        var pieces: [String] = []
        collectScalars(value, into: &pieces)
        return pieces.joined(separator: " ")
    }

    private static func collectText(_ value: JSONValue, into pieces: inout [String]) {
        switch value {
        case .object(let members):
            if let text = members["text"]?.stringValue { pieces.append(text) }
            for key in members.keys.sorted() where key != "text" {
                collectText(members[key]!, into: &pieces)
            }
        case .array(let members):
            for member in members { collectText(member, into: &pieces) }
        case .string(let text):
            pieces.append(text)
        default:
            break
        }
    }

    private static func collectScalars(_ value: JSONValue, into pieces: inout [String]) {
        switch value {
        case .object(let members):
            for key in members.keys.sorted() { collectScalars(members[key]!, into: &pieces) }
        case .array(let members):
            for member in members { collectScalars(member, into: &pieces) }
        case .string(let text):
            pieces.append(text)
        case .number(let text):
            pieces.append(text)
        default:
            break
        }
    }
}
