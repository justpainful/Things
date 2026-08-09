import Foundation
import GRDB

/// The fallback index, used when the linked SQLCipher binary has no FTS5 module.
///
/// A plain table with the same columns as `thing_fts`, queried with `LIKE`. Slower and
/// without ranking or snippets, but it keeps every access path working — and search is the
/// spine of this app, so degrading it is far better than losing it. If this ever becomes
/// the permanent answer, the fix is to build SQLCipher from source with `--enable-fts5`,
/// not to rewrite anything above this line.
public struct LikeSearchIndex: SearchIndex {

    public let name = "like"
    public let tableName = SchemaSQL.fallbackSearchTableName

    public init() {}

    public func upsert(_ db: Database, document: SearchDocument) throws {
        let columns = SchemaSQL.searchColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = SchemaSQL.searchColumns.map { _ in "?" }.joined(separator: ", ")
        let assignments = SchemaSQL.searchColumns
            .filter { $0 != "thing_id" }
            .map { "\"\($0)\" = excluded.\"\($0)\"" }
            .joined(separator: ", ")
        try db.execute(
            sql: """
            INSERT INTO \(tableName) (\(columns)) VALUES (\(placeholders))
            ON CONFLICT(thing_id) DO UPDATE SET \(assignments)
            """,
            arguments: StatementArguments(document.orderedValues)
        )
    }

    public func remove(_ db: Database, thingID: String) throws {
        try db.execute(sql: "DELETE FROM \(tableName) WHERE thing_id = ?", arguments: [thingID])
    }

    public func removeAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM \(tableName)")
    }

    public func matchingThingIDs(_ db: Database, query: SearchQuery, limit: Int) throws -> [String] {
        var needles = query.terms + query.phrases
        needles = needles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }

        let searchable = SchemaSQL.searchColumns.filter { $0 != "thing_id" }
        var clauses: [String] = []
        // Typed as an array of *optional* existentials so it binds to the
        // `StatementArguments.init(_:)` overload whose Element is
        // `(any DatabaseValueConvertible)?`. A plain `[any DatabaseValueConvertible]` does
        // not satisfy the `Element: DatabaseValueConvertible` overload, because an
        // existential does not conform to its own protocol.
        var arguments: [(any DatabaseValueConvertible)?] = []

        for needle in needles {
            let anyColumn = searchable
                .map { "\"\($0)\" LIKE ? ESCAPE '\\'" }
                .joined(separator: " OR ")
            clauses.append("(\(anyColumn))")
            for _ in searchable {
                arguments.append("%" + LikeSearchIndex.escape(needle) + "%")
            }
        }
        for excluded in query.excludedTerms where !excluded.isEmpty {
            let anyColumn = searchable
                .map { "\"\($0)\" LIKE ? ESCAPE '\\'" }
                .joined(separator: " OR ")
            clauses.append("NOT (\(anyColumn))")
            for _ in searchable {
                arguments.append("%" + LikeSearchIndex.escape(excluded) + "%")
            }
        }

        arguments.append(limit)
        return try String.fetchAll(
            db,
            sql: """
            SELECT thing_id FROM \(tableName)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY title COLLATE NOCASE
            LIMIT ?
            """,
            arguments: StatementArguments(arguments)
        )
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
