import Foundation

/// `spec/schema.sql`, loaded verbatim from the bundle and split into statements.
///
/// Two adjustments happen at execution time, both documented here rather than by editing
/// the normative file:
///
///  * `PRAGMA` statements are skipped. `journal_mode` cannot run inside the transaction a
///    migration executes in, and GRDB owns `foreign_keys` through `Configuration`.
///  * The FTS5 virtual table is skipped when the linked SQLCipher binary has no FTS5
///    module, and a plain fallback table is created instead. Whether Zetetic's prebuilt
///    binary includes FTS5 is genuinely unverified, so the schema loader has to cope with
///    both answers rather than assume one.
public enum SchemaSQL {

    public static let ftsTableName = "thing_fts"
    public static let fallbackSearchTableName = "thing_search"

    public static func bundledText() throws -> String {
        guard let url = BundledResource.url(named: "schema", extension: "sql") else {
            throw ThingsError.resourceMissing("schema.sql")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ThingsError.resourceMissing("schema.sql could not be read as UTF-8")
        }
        return text
    }

    /// Splits on top-level semicolons, ignoring `--` line comments and semicolons inside
    /// quoted literals. The canonical schema contains neither of those hazards today, but a
    /// naive `split(separator: ";")` would be a landmine the first time it does.
    public static func statements(in sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var inLineComment = false

        let characters = Array(sql)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let following: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                if character == "\n" { inLineComment = false }
                index += 1
                continue
            }
            if !inSingleQuote && !inDoubleQuote && character == "-" && following == "-" {
                inLineComment = true
                index += 2
                continue
            }
            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                current.append(character)
                index += 1
                continue
            }
            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                current.append(character)
                index += 1
                continue
            }
            if character == ";" && !inSingleQuote && !inDoubleQuote {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { statements.append(trimmed) }
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }

        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { statements.append(trailing) }
        return statements
    }

    public static func isPragma(_ statement: String) -> Bool {
        statement.lowercased().hasPrefix("pragma")
    }

    public static func isFTS5VirtualTable(_ statement: String) -> Bool {
        let lowered = statement.lowercased()
        return lowered.contains("create virtual table") && lowered.contains("using fts5")
    }

    /// Columns of `thing_fts`, in schema order. The fallback table mirrors them exactly so
    /// the two search implementations write identical documents.
    public static let searchColumns = [
        "thing_id", "title", "labels", "values", "notes",
        "tags", "urls", "paths", "filenames", "collections", "markers"
    ]

    public static var fallbackSearchTableSQL: String {
        let columns = searchColumns
            .map { $0 == "thing_id" ? "thing_id TEXT PRIMARY KEY" : "\"\($0)\" TEXT NOT NULL DEFAULT ''" }
            .joined(separator: ",\n  ")
        return """
        CREATE TABLE IF NOT EXISTS \(fallbackSearchTableName) (
          \(columns)
        )
        """
    }
}
