import Foundation
import GRDB

/// The bridge between oplog JSON and table columns.
///
/// Every column an oplog record may touch is listed here explicitly. That is deliberate:
/// `attrs_json` comes from the network during sync, so building `UPDATE … SET` from
/// attacker-influenced key names would be an injection hole. Unknown keys are dropped, not
/// interpolated.
enum EntityColumns {

    enum ColumnType {
        case text
        case integer
        case real
        /// BLOB, carried as `{"$b64": "<base64>"}` — `spec/oplog.md` §3. The wrapper, not a
        /// bare base64 string, is what the TypeScript core writes and reads; a bare string
        /// would arrive there as *text* and silently overwrite a secret field's ciphertext
        /// with its own base64.
        case blob
    }

    /// The normative JSON form of a BLOB attribute.
    static let blobWrapperKey = "$b64"

    static func blobJSON(_ data: Data) -> JSONValue {
        .object([blobWrapperKey: .string(data.base64EncodedString())])
    }

    /// Accepts the normative wrapper, and also a bare base64 string — the shape an earlier
    /// draft of this file wrote, so a local oplog written by that draft still replays.
    static func blobData(_ json: JSONValue) -> Data? {
        if let wrapped = json[blobWrapperKey]?.stringValue {
            return Data(base64Encoded: wrapped)
        }
        if let text = json.stringValue {
            return Data(base64Encoded: text)
        }
        return nil
    }

    static let schemas: [EntityType: [(name: String, type: ColumnType)]] = [
        .thing: [
            ("title", .text), ("icon_json", .text), ("cover_object", .text),
            ("is_pinned", .integer), ("is_locked", .integer), ("is_archived", .integer),
            ("is_template", .integer),
            ("created_at", .text), ("updated_at", .text), ("viewed_at", .text), ("deleted_at", .text),
            ("version_vector", .text)
        ],
        .section: [
            ("thing_id", .text), ("title", .text), ("sort_order", .real),
            ("created_at", .text), ("updated_at", .text), ("version_vector", .text)
        ],
        .field: [
            ("thing_id", .text), ("section_id", .text), ("sort_order", .real),
            ("kind", .text), ("variant", .text), ("label", .text),
            ("value_text", .text), ("value_json", .text), ("value_cipher", .blob),
            ("object_hash", .text), ("file_ref_id", .text),
            ("is_secret", .integer),
            ("created_at", .text), ("updated_at", .text), ("version_vector", .text)
        ],
        .collection: [
            ("name", .text), ("icon_json", .text), ("sort_order", .real), ("parent_id", .text),
            ("is_smart", .integer), ("is_system", .integer), ("smart_query", .text),
            ("created_at", .text), ("updated_at", .text), ("version_vector", .text)
        ],
        .tag: [
            ("name", .text), ("color", .text), ("created_at", .text)
        ],
        .fileRef: [
            ("device_id", .text), ("path", .text), ("is_directory", .integer),
            ("size_at_link", .integer), ("mtime_at_link", .text), ("content_hash", .text),
            ("last_seen_at", .text), ("status", .text), ("created_at", .text)
        ]
    ]

    static func schema(for entityType: EntityType) throws -> [(name: String, type: ColumnType)] {
        guard let schema = schemas[entityType] else {
            // `member` and `thing_tag` are join rows with composite keys; they are created
            // and deleted whole rather than patched, so they are not in this table.
            throw ThingsError.unsupportedEntityType(entityType.rawValue)
        }
        return schema
    }

    // MARK: - Snapshot

    /// Reads the current row as oplog JSON — this becomes `prev_json`.
    static func snapshot(_ db: Database, entityType: EntityType, entityID: String) throws -> [String: JSONValue]? {
        let schema = try schema(for: entityType)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM \(entityType.tableName) WHERE id = ?",
            arguments: [entityID]
        ) else { return nil }

        var attributes: [String: JSONValue] = [:]
        for column in schema {
            attributes[column.name] = value(from: row, column: column.name, type: column.type)
        }
        return attributes
    }

    static func value(from row: Row, column: String, type: ColumnType) -> JSONValue {
        switch type {
        case .text:
            let text: String? = row[column]
            return text.map { JSONValue.string($0) } ?? .null
        case .integer:
            let number: Int64? = row[column]
            return number.map { JSONValue.number(String($0)) } ?? .null
        case .real:
            let number: Double? = row[column]
            return number.map { JSONValue.number(canonicalDouble($0)) } ?? .null
        case .blob:
            let data: Data? = row[column]
            return data.map { blobJSON($0) } ?? .null
        }
    }

    /// `2.5` not `2.5000000000000004`, and `3` not `3.0`, matching JavaScript's
    /// `Number#toString` for the values we actually produce.
    static func canonicalDouble(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - Apply

    static func databaseValue(_ json: JSONValue, type: ColumnType) -> (any DatabaseValueConvertible)? {
        if case .null = json { return nil }
        switch type {
        case .text:
            if case .string(let text) = json { return text }
            return json.canonicalJSON
        case .integer:
            if let number = json.intValue { return number }
            if let flag = json.boolValue { return flag ? 1 : 0 }
            return nil
        case .real:
            return json.doubleValue
        case .blob:
            return blobData(json)
        }
    }

    /// Patches an existing row with whatever subset of allow-listed columns is present.
    static func apply(_ db: Database,
                      entityType: EntityType,
                      entityID: String,
                      attributes: [String: JSONValue],
                      clock: ThingsClock) throws {
        let schema = try schema(for: entityType)
        var assignments: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []

        for column in schema {
            guard let json = attributes[column.name] else { continue }
            assignments.append("\"\(column.name)\" = ?")
            arguments.append(databaseValue(json, type: column.type))
        }
        guard !assignments.isEmpty else { return }

        // Touch `updated_at` unless the caller was explicit about it, so a restore is
        // visibly recent in Recents.
        if attributes["updated_at"] == nil, schema.contains(where: { $0.name == "updated_at" }) {
            assignments.append("\"updated_at\" = ?")
            arguments.append(clock.nowISO8601())
        }

        arguments.append(entityID)
        try db.execute(
            sql: "UPDATE \(entityType.tableName) SET \(assignments.joined(separator: ", ")) WHERE id = ?",
            arguments: StatementArguments(arguments)
        )
    }

    /// Re-creates a deleted row from its `prev_json` — the Undo-a-delete path.
    static func insert(_ db: Database,
                       entityType: EntityType,
                       entityID: String,
                       attributes: [String: JSONValue],
                       clock: ThingsClock) throws {
        let schema = try schema(for: entityType)
        var columns = ["id"]
        var arguments: [(any DatabaseValueConvertible)?] = [entityID]

        for column in schema {
            guard let json = attributes[column.name] else { continue }
            columns.append(column.name)
            arguments.append(databaseValue(json, type: column.type))
        }
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        let quoted = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        try db.execute(
            sql: "INSERT OR REPLACE INTO \(entityType.tableName) (\(quoted)) VALUES (\(placeholders))",
            arguments: StatementArguments(arguments)
        )
    }

    /// Only the columns that actually changed, so `attrs_json` stays small and History can
    /// say "Changed password" rather than "Changed everything".
    static func diff(previous: [String: JSONValue]?, current: [String: JSONValue]) -> [String: JSONValue] {
        guard let previous else { return current }
        var changed: [String: JSONValue] = [:]
        for (key, value) in current where previous[key] != value {
            changed[key] = value
        }
        return changed
    }
}
