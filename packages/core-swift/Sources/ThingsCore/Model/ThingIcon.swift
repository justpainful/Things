import Foundation

/// `icon_json` — `{type:'symbol'|'emoji'|'object'|'auto', value, tint}`.
///
/// `.auto` is the "Things picks an icon from the content" behaviour: a deterministic local
/// function of the title and the field kinds present. No AI, no network, and — critically
/// for the Screenshot Tour — the same input always produces the same icon.
public struct ThingIcon: Hashable, Sendable {

    public enum Kind: String, Sendable, Hashable {
        case symbol, emoji, object, auto
    }

    public var kind: Kind
    public var value: String?
    public var tint: String?

    public init(kind: Kind, value: String? = nil, tint: String? = nil) {
        self.kind = kind
        self.value = value
        self.tint = tint
    }

    public static let automatic = ThingIcon(kind: .auto)

    public var json: String {
        var members: [String: JSONValue] = ["type": .string(kind.rawValue)]
        if let value { members["value"] = .string(value) }
        if let tint { members["tint"] = .string(tint) }
        return JSONValue.object(members).canonicalJSON
    }

    public static func parse(_ text: String?) -> ThingIcon {
        guard let text, !text.isEmpty,
              let parsed = try? JSONValue.parse(text),
              let typeText = parsed["type"]?.stringValue,
              let kind = Kind(rawValue: typeText)
        else { return .automatic }
        return ThingIcon(kind: kind,
                         value: parsed["value"]?.stringValue,
                         tint: parsed["tint"]?.stringValue)
    }

    /// Resolves `.auto` into a concrete SF Symbol name and a tint bucket.
    ///
    /// Deterministic by construction: the symbol comes from the dominant field variant
    /// when there is one, and the tint from a stable hash of the title.
    public static func resolveAutomatic(title: String,
                                        variants: [String],
                                        registry: FieldKindRegistry) -> (symbol: String, tint: String) {
        var counts: [String: Int] = [:]
        for variant in variants {
            counts[variant, default: 0] += 1
        }
        // Ties broken alphabetically so the result never depends on row order.
        let dominant = counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .first?.key

        let symbol = registry.variant(dominant)?.symbol ?? "square.stack"
        return (symbol, tintName(for: title))
    }

    /// FNV-1a over the title, bucketed. Stable across processes and platforms, unlike
    /// `String.hashValue` which is seeded per launch.
    public static func tintName(for title: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in title.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let palette = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "teal", "mint"]
        return palette[Int(hash % UInt64(palette.count))]
    }
}
