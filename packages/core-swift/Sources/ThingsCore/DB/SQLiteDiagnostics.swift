import Foundation
import GRDB

/// Startup diagnostic.
///
/// It is genuinely unverified whether FTS5 is compiled into the SQLCipher binary that ships
/// inside Zetetic's GRDB fork. GRDB's own `SQLITE_ENABLE_FTS5` flag only exposes the *Swift*
/// API; the module has to exist in the linked binary as well. Search is load-bearing here —
/// five of the six access paths depend on it — so the app finds out on the first connection
/// and says so, rather than failing at the first query.
public struct SQLiteDiagnostics: Sendable, Equatable {

    public var sqliteVersion: String
    public var cipherVersion: String?
    public var cipherProvider: String?
    public var compileOptions: [String]
    /// Authoritative: the result of actually creating an FTS5 table, not of reading a flag.
    public var hasFTS5: Bool
    /// What `PRAGMA compile_options` claimed, for the log line.
    public var compileOptionsMentionFTS5: Bool
    public var isEncrypted: Bool

    public var summary: String {
        var lines: [String] = []
        lines.append("SQLite \(sqliteVersion)")
        if let cipherVersion {
            lines.append("SQLCipher \(cipherVersion)\(cipherProvider.map { " (\($0))" } ?? "")")
        } else {
            lines.append("SQLCipher: not detected")
        }
        lines.append("Database encryption: \(isEncrypted ? "on" : "OFF")")
        lines.append("FTS5: \(hasFTS5 ? "available" : "MISSING — falling back to LIKE search")")
        lines.append("compile_options mention FTS5: \(compileOptionsMentionFTS5)")
        return lines.joined(separator: "\n")
    }

    /// One-line form for the CI log, which is where this will actually be read.
    public var logLine: String {
        "[ThingsCore] sqlite=\(sqliteVersion) sqlcipher=\(cipherVersion ?? "none") "
            + "encrypted=\(isEncrypted) fts5=\(hasFTS5) fts5_in_compile_options=\(compileOptionsMentionFTS5)"
    }

    /// `try?` applied to a call that already returns an Optional produces a double
    /// optional. Flattening it in one helper keeps that out of every call site.
    private static func optionalString(_ db: Database, _ sql: String) -> String? {
        (try? String.fetchOne(db, sql: sql)) ?? nil
    }

    static func probe(_ db: Database, isEncrypted: Bool) -> SQLiteDiagnostics {
        let version = optionalString(db, "SELECT sqlite_version()") ?? "unknown"
        let options = (try? String.fetchAll(db, sql: "PRAGMA compile_options")) ?? []
        // `PRAGMA cipher_version` returns no row at all when SQLCipher is not linked, and
        // raises when the pragma is unknown — both are answers, neither is a failure.
        let cipher = optionalString(db, "PRAGMA cipher_version")
        let provider = optionalString(db, "PRAGMA cipher_provider")

        let mentionsFTS5 = options.contains { $0.uppercased().contains("ENABLE_FTS5") }

        // The only answer that matters: can we actually make one?
        var works = false
        do {
            try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS temp.things_fts5_probe USING fts5(probe)")
            try db.execute(sql: "DROP TABLE IF EXISTS temp.things_fts5_probe")
            works = true
        } catch {
            works = false
        }

        return SQLiteDiagnostics(
            sqliteVersion: version,
            cipherVersion: cipher,
            cipherProvider: provider,
            compileOptions: options,
            hasFTS5: works,
            compileOptionsMentionFTS5: mentionsFTS5,
            isEncrypted: isEncrypted
        )
    }
}
