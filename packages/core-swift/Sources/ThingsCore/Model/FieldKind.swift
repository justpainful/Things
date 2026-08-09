import Foundation

/// The base kind of a Field — *how* it is stored and rendered.
///
/// Deliberately a string wrapper and **not** an enum. `spec/field-kinds.json` is the
/// normative registry; an enum here would be a second, drifting copy of it, and the whole
/// point of the kind/variant split is that the app never carries its own type list.
/// The named statics below are ergonomic shorthands for the values the schema's CHECK
/// constraint already pins — they are not a definition.
public struct FieldKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let text = FieldKind("text")
    public static let longText = FieldKind("longText")
    public static let richText = FieldKind("richText")
    public static let number = FieldKind("number")
    public static let boolean = FieldKind("boolean")
    public static let date = FieldKind("date")
    public static let url = FieldKind("url")
    public static let path = FieldKind("path")
    public static let secret = FieldKind("secret")
    public static let attachment = FieldKind("attachment")
    public static let color = FieldKind("color")
    public static let code = FieldKind("code")
    public static let geo = FieldKind("geo")
    public static let money = FieldKind("money")
    public static let relation = FieldKind("relation")
    public static let tagList = FieldKind("tagList")
}

/// Which column carries a field's value. Mirrors `kinds[].storage` in the registry.
public enum FieldStorage: String, Sendable, Codable {
    case valueText = "value_text"
    case valueJSON = "value_json"
    case valueCipher = "value_cipher"
    case objectHash = "object_hash"
    case fileRefID = "file_ref_id"
    case thingTag = "thing_tag"
}
