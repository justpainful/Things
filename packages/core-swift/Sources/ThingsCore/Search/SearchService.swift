import Foundation
import GRDB

/// Runs a `SearchQuery` against the library.
///
/// Free text goes through whichever `SearchIndex` is active. Structured filters are SQL
/// predicates over the materialised tables — precise, and independent of how the FTS
/// tokeniser happens to chop `has:password`.
public struct SearchService: Sendable {

    public let index: SearchIndex
    public let registry: FieldKindRegistry
    public let clock: ThingsClock

    public init(index: SearchIndex, registry: FieldKindRegistry, clock: ThingsClock) {
        self.index = index
        self.registry = registry
        self.clock = clock
    }

    public static let defaultLimit = 200

    public func search(_ db: Database, query: SearchQuery, limit: Int = SearchService.defaultLimit) throws -> [SearchHit] {
        var candidateIDs: [String]?
        if query.hasFreeText {
            candidateIDs = try index.matchingThingIDs(db, query: query, limit: limit * 4)
            if candidateIDs?.isEmpty == true { return [] }
        }

        // The two implicit filters, unless the query asks for exactly what they hide.
        let wantsTrash = query.filters.contains { $0.key == "is" && !$0.negated && ($0.value == "deleted" || $0.value == "trashed") }
        let wantsTemplates = query.filters.contains { $0.key == "is" && !$0.negated && $0.value == "template" }

        var clauses: [String] = []
        if !wantsTrash { clauses.append("thing.deleted_at IS NULL") }
        if !wantsTemplates { clauses.append("thing.is_template = 0") }
        if clauses.isEmpty { clauses.append("1") }
        var arguments: [(any DatabaseValueConvertible)?] = []

        if let candidateIDs {
            let placeholders = candidateIDs.map { _ in "?" }.joined(separator: ", ")
            clauses.append("thing.id IN (\(placeholders))")
            arguments.append(contentsOf: candidateIDs.map { $0 as (any DatabaseValueConvertible)? })
        }

        for filter in query.filters {
            guard let (clause, filterArguments) = predicate(for: filter) else { continue }
            clauses.append(filter.negated ? "NOT (\(clause))" : clause)
            arguments.append(contentsOf: filterArguments)
        }

        let ordering = orderClause(for: query)
        arguments.append(limit)

        let sql = """
        SELECT thing.* FROM thing
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY \(ordering)
        LIMIT ?
        """
        let things = try Thing.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        // Preserve relevance order when the index produced one.
        if let candidateIDs, query.sortKey == nil {
            var byID: [String: Thing] = [:]
            for thing in things { byID[thing.id] = thing }
            return candidateIDs.compactMap { id in
                guard let thing = byID[id] else { return nil }
                return SearchHit(thingID: thing.id, title: thing.title, snippet: nil, rank: 0)
            }
        }
        return things.map { SearchHit(thingID: $0.id, title: $0.title, snippet: nil, rank: 0) }
    }

    /// Count without materialising rows — used by the filter chips.
    public func count(_ db: Database, query: SearchQuery) throws -> Int {
        try search(db, query: query, limit: SearchService.defaultLimit).count
    }

    // MARK: - Filters

    func orderClause(for query: SearchQuery) -> String {
        switch query.sortKey {
        case "created": return "thing.created_at DESC"
        case "modified": return "thing.updated_at DESC"
        case "viewed": return "thing.viewed_at DESC"
        case "title": return "thing.title COLLATE NOCASE ASC"
        default: return "thing.is_pinned DESC, thing.updated_at DESC"
        }
    }

    func predicate(for filter: SearchQuery.Filter) -> (String, [(any DatabaseValueConvertible)?])? {
        let value = filter.value
        switch filter.key {

        case "tag":
            return ("""
            EXISTS (SELECT 1 FROM thing_tag
                    JOIN tag ON tag.id = thing_tag.tag_id
                    WHERE thing_tag.thing_id = thing.id AND tag.name = ? COLLATE NOCASE)
            """, [value])

        case "collection":
            return ("""
            EXISTS (SELECT 1 FROM collection_member
                    JOIN collection ON collection.id = collection_member.collection_id
                    WHERE collection_member.thing_id = thing.id
                      AND (collection.name = ? COLLATE NOCASE OR collection.id = ?))
            """, [value, value])

        case "device":
            return ("""
            EXISTS (SELECT 1 FROM field
                    JOIN file_ref ON file_ref.id = field.file_ref_id
                    JOIN device   ON device.id = file_ref.device_id
                    WHERE field.thing_id = thing.id
                      AND (device.name = ? COLLATE NOCASE OR device.id = ?))
            """, [value, value])

        case "kind":
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.kind = ?)", [value])

        case "variant", "type":
            // `type:image` is a marker on the registry entry, not a column. Resolve it back
            // to the set of variants that declare it, so adding a new gallery variant to
            // field-kinds.json needs no code change here.
            let marker = filter.key == "type" ? "type:\(value)" : nil
            let variantIDs: [String]
            if let marker {
                variantIDs = registry.variants.filter { $0.marker == marker }.map { $0.id }
            } else {
                variantIDs = [value]
            }
            guard !variantIDs.isEmpty else { return ("0", []) }
            let placeholders = variantIDs.map { _ in "?" }.joined(separator: ", ")
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.variant IN (\(placeholders)))",
                    variantIDs.map { $0 as (any DatabaseValueConvertible)? })

        case "has":
            return hasPredicate(value)

        case "is":
            return isPredicate(value)

        case "created", "modified":
            let column = filter.key == "created" ? "thing.created_at" : "thing.updated_at"
            guard let range = DateFilterRange.parse(value),
                  let bounds = range.bounds(nowMilliseconds: clock.nowMilliseconds())
            else { return nil }
            return ("(\(column) >= ? AND \(column) < ?)", [bounds.lower, bounds.upper])

        case "size":
            guard let size = SizeFilter.parse(value) else { return nil }
            return ("""
            EXISTS (SELECT 1 FROM field
                    JOIN object ON object.hash = field.object_hash
                    WHERE field.thing_id = thing.id AND object.byte_size \(size.sqlComparison) ?)
            """, [size.bytes])

        case "sort":
            return nil          // handled by `orderClause`

        default:
            return nil
        }
    }

    private func hasPredicate(_ value: String) -> (String, [(any DatabaseValueConvertible)?])? {
        switch value.lowercased() {
        case "password", "key", "secret":
            let marker = "has:\(value.lowercased())"
            let variantIDs = registry.variants.filter { $0.marker == marker }.map { $0.id }
            guard !variantIDs.isEmpty else { return ("0", []) }
            let placeholders = variantIDs.map { _ in "?" }.joined(separator: ", ")
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.variant IN (\(placeholders)))",
                    variantIDs.map { $0 as (any DatabaseValueConvertible)? })
        case "file", "attachment":
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.kind = 'attachment')", [])
        case "url", "link":
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.kind = 'url')", [])
        case "path":
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.kind = 'path')", [])
        case "tag":
            return ("EXISTS (SELECT 1 FROM thing_tag WHERE thing_tag.thing_id = thing.id)", [])
        case "note":
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.kind IN ('richText','longText'))", [])
        case "relation":
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.kind = 'relation')", [])
        default:
            return ("EXISTS (SELECT 1 FROM field WHERE field.thing_id = thing.id AND field.variant = ?)", [value])
        }
    }

    private func isPredicate(_ value: String) -> (String, [(any DatabaseValueConvertible)?])? {
        switch value.lowercased() {
        case "pinned": return ("thing.is_pinned = 1", [])
        case "locked": return ("thing.is_locked = 1", [])
        case "archived": return ("thing.is_archived = 1", [])
        case "template": return ("thing.is_template = 1", [])
        case "deleted", "trashed": return ("thing.deleted_at IS NOT NULL", [])
        case "missing":
            return ("""
            EXISTS (SELECT 1 FROM field
                    JOIN file_ref ON file_ref.id = field.file_ref_id
                    WHERE field.thing_id = thing.id AND file_ref.status = 'missing')
            """, [])
        default:
            return nil
        }
    }
}
