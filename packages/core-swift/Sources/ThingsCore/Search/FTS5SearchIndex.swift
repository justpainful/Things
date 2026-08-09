import Foundation
import GRDB

/// The real index: `thing_fts`, an FTS5 external-content-free table declared verbatim in
/// `spec/schema.sql`.
///
/// Written with raw SQL rather than GRDB's FTS5 helpers. The helpers are gated behind
/// `SQLITE_ENABLE_FTS5` at GRDB build time, and this app has to compile whether or not the
/// linked SQLCipher binary carries the module — the *runtime* probe decides which index is
/// used, and a compile-time dependency on the Swift API would defeat that.
public struct FTS5SearchIndex: SearchIndex {

    public let name = "fts5"
    public let tableName = SchemaSQL.ftsTableName

    public init() {}

    public func upsert(_ db: Database, document: SearchDocument) throws {
        try remove(db, thingID: document.thingID)
        let columns = SchemaSQL.searchColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = SchemaSQL.searchColumns.map { _ in "?" }.joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO \(tableName) (\(columns)) VALUES (\(placeholders))",
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
        guard let pattern = FTS5SearchIndex.matchPattern(for: query) else { return [] }
        return try String.fetchAll(
            db,
            sql: """
            SELECT thing_id FROM \(tableName)
            WHERE \(tableName) MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            arguments: [pattern, limit]
        )
    }

    public func snippet(_ db: Database, thingID: String, query: SearchQuery) throws -> String? {
        guard let pattern = FTS5SearchIndex.matchPattern(for: query) else { return nil }
        return try String.fetchOne(
            db,
            sql: """
            SELECT snippet(\(tableName), -1, '', '', '…', 12) FROM \(tableName)
            WHERE \(tableName) MATCH ? AND thing_id = ?
            LIMIT 1
            """,
            arguments: [pattern, thingID]
        )
    }

    /// Builds an FTS5 MATCH expression.
    ///
    /// Every user token is quoted, which turns it into a literal string and neutralises the
    /// FTS5 operators (`AND`, `OR`, `NOT`, `NEAR`, `*`, `^`, `:`, parentheses). Without this
    /// a title containing "OR" would silently rewrite the user's query — and a malformed
    /// expression raises an SQL error rather than returning nothing.
    static func matchPattern(for query: SearchQuery) -> String? {
        var clauses: [String] = []
        for term in query.terms {
            let cleaned = sanitize(term)
            guard !cleaned.isEmpty else { continue }
            // Trailing `*` on the last token is what makes as-you-type search feel right.
            clauses.append("\"\(cleaned)\"*")
        }
        for phrase in query.phrases {
            let cleaned = sanitize(phrase)
            guard !cleaned.isEmpty else { continue }
            clauses.append("\"\(cleaned)\"")
        }
        guard !clauses.isEmpty else { return nil }

        var expression = clauses.joined(separator: " AND ")
        let exclusions = query.excludedTerms.map { sanitize($0) }.filter { !$0.isEmpty }
        if !exclusions.isEmpty {
            expression += " NOT (" + exclusions.map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
        }
        return expression
    }

    /// Doubles embedded quotes and drops characters FTS5 treats as syntax even inside a
    /// quoted string.
    static func sanitize(_ token: String) -> String {
        var out = ""
        for character in token {
            switch character {
            case "\"":
                out += "\"\""
            case "*", "^", "(", ")", ":":
                out += " "
            default:
                out.append(character)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
