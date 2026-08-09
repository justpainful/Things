import Foundation

/// A tiny JSON tree with a *canonical* serialisation: object keys sorted, no whitespace,
/// numbers carried as their original decimal string.
///
/// Two reasons this exists instead of `JSONSerialization`:
///   1. `attrs_json` and `prev_json` in the oplog are compared across the Swift and
///      TypeScript cores. Key order and float formatting have to be identical or the
///      conformance vectors are meaningless.
///   2. Numbers survive as text. `0.1 + 0.2` must not become `0.30000000000000004` on one
///      side and `0.3` on the other.
public enum JSONValue: Equatable, Sendable {

    case null
    case bool(Bool)
    /// The decimal representation exactly as written. Never parsed into a Double.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Convenience

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let text): return text == "1" ? true : (text == "0" ? false : nil)
        case .string(let text): return text == "1" ? true : (text == "0" ? false : nil)
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let text): return Int(text)
        case .string(let text): return Int(text)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let text): return Double(text)
        case .string(let text): return Double(text)
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public static func number(_ value: Int) -> JSONValue { .number(String(value)) }

    // MARK: - Canonical output

    public var canonicalJSON: String {
        var out = ""
        write(into: &out)
        return out
    }

    public var canonicalData: Data { Data(canonicalJSON.utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .number(let text):
            out += text.isEmpty ? "0" : text
        case .string(let text):
            JSONValue.writeString(text, into: &out)
        case .array(let members):
            out += "["
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                member.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            // Sorted by UTF-8 scalar order, which is what JS `Array#sort` on plain ASCII
            // keys also produces.
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                JSONValue.writeString(key, into: &out)
                out += ":"
                members[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    var hex = String(scalar.value, radix: 16, uppercase: false)
                    while hex.count < 4 { hex = "0" + hex }
                    out += "\\u" + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: - Parsing

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ThingsError.registryInvalid("not JSON: \(error)")
        }
        return convert(object)
    }

    static func convert(_ object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let value as NSNumber:
            // NSNumber loses the bool/number distinction unless we ask the type encoding.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let doubleValue = value.doubleValue
            if doubleValue == doubleValue.rounded() && abs(doubleValue) < 9_007_199_254_740_992 {
                return .number(String(value.int64Value))
            }
            return .number(String(doubleValue))
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.map { convert($0) })
        case let value as [String: Any]:
            var members: [String: JSONValue] = [:]
            for (key, member) in value {
                members[key] = convert(member)
            }
            return .object(members)
        default:
            return .null
        }
    }
}
