import Foundation

/// `spec/field-kinds.json`, loaded as data.
///
/// Adding "Threads" tomorrow is a one-line JSON change. Nothing in this file, and nothing
/// in the app, enumerates the variants.
public struct FieldKindRegistry: Sendable {

    // MARK: - Shapes

    public struct Kind: Sendable, Codable {
        public var storage: FieldStorage
        public var alt: FieldStorage?
        public var multiline: Bool?
        public var alwaysSecret: Bool?
        public var values: [String]?
        public var format: String?
        public var shape: String?
        public var note: String?

        public var isMultiline: Bool { multiline ?? false }
        public var isAlwaysSecret: Bool { alwaysSecret ?? false }
    }

    public struct Action: Sendable, Codable, Identifiable, Hashable {
        public var id: String = ""
        public var label: String
        public var gated: Bool?
        public var deviceScoped: Bool?

        public var isGated: Bool { gated ?? false }
        public var isDeviceScoped: Bool { deviceScoped ?? false }

        private enum CodingKeys: String, CodingKey { case label, gated, deviceScoped }
    }

    public struct Variant: Sendable, Codable, Identifiable, Hashable {
        public var id: String
        public var kind: FieldKind
        public var label: String
        public var symbol: String
        /// Regex matched against a URL to auto-detect this variant.
        public var match: String?
        /// Regex the value must satisfy.
        public var validate: String?
        public var actions: [String]
        /// Search marker contributed by a field of this variant, e.g. `has:password`.
        public var marker: String?
        /// Belongs in the media gallery rather than the field list.
        public var gallery: Bool?
        public var max: Int?

        public var showsInGallery: Bool { gallery ?? false }

        private enum CodingKeys: String, CodingKey {
            case id, kind, label, symbol, match, validate, actions, marker, gallery, max
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            kind = FieldKind(try container.decode(String.self, forKey: .kind))
            label = try container.decode(String.self, forKey: .label)
            symbol = try container.decode(String.self, forKey: .symbol)
            match = try container.decodeIfPresent(String.self, forKey: .match)
            validate = try container.decodeIfPresent(String.self, forKey: .validate)
            actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
            marker = try container.decodeIfPresent(String.self, forKey: .marker)
            gallery = try container.decodeIfPresent(Bool.self, forKey: .gallery)
            max = try container.decodeIfPresent(Int.self, forKey: .max)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind.rawValue, forKey: .kind)
            try container.encode(label, forKey: .label)
            try container.encode(symbol, forKey: .symbol)
            try container.encodeIfPresent(match, forKey: .match)
            try container.encodeIfPresent(validate, forKey: .validate)
            try container.encode(actions, forKey: .actions)
            try container.encodeIfPresent(marker, forKey: .marker)
            try container.encodeIfPresent(gallery, forKey: .gallery)
            try container.encodeIfPresent(max, forKey: .max)
        }
    }

    public struct TemplateField: Sendable, Codable, Hashable {
        public var variant: String
        public var label: String
    }

    public struct TemplateSection: Sendable, Codable, Hashable {
        public var title: String?
        public var fields: [TemplateField]
    }

    public struct Template: Sendable, Codable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public var symbol: String
        public var sections: [TemplateSection]

        public var fieldCount: Int {
            sections.reduce(0) { $0 + $1.fields.count }
        }
    }

    public struct SmartView: Sendable, Codable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public var symbol: String
        public var query: String
    }

    // MARK: - Contents

    public let version: Int
    public let kinds: [String: Kind]
    public let actions: [String: Action]
    public let variants: [Variant]
    public let templates: [Template]
    public let smartViews: [SmartView]

    private let variantsByID: [String: Variant]
    private let variantsByKind: [String: [Variant]]

    // MARK: - Loading

    private struct Document: Decodable {
        var version: Int
        var kinds: [String: Kind]
        var actions: [String: Action]
        var variants: [Variant]
        var templates: [Template]
        var smartViews: [SmartView]
    }

    public init(data: Data) throws {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw ThingsError.registryInvalid(String(describing: error))
        }
        guard !document.variants.isEmpty else {
            throw ThingsError.registryInvalid("no variants")
        }
        version = document.version
        kinds = document.kinds
        var namedActions: [String: Action] = [:]
        for (identifier, action) in document.actions {
            var copy = action
            copy.id = identifier
            namedActions[identifier] = copy
        }
        actions = namedActions
        variants = document.variants
        templates = document.templates
        smartViews = document.smartViews

        var byID: [String: Variant] = [:]
        var byKind: [String: [Variant]] = [:]
        for variant in document.variants {
            byID[variant.id] = variant
            byKind[variant.kind.rawValue, default: []].append(variant)
        }
        variantsByID = byID
        variantsByKind = byKind
    }

    /// Loads the copy bundled with this package. The bundled file is asserted
    /// byte-identical to `spec/field-kinds.json` by `RegistryParityTests`.
    public static func loadBundled() throws -> FieldKindRegistry {
        if let cached = RegistryCache.shared.value { return cached }
        guard let url = BundledResource.url(named: "field-kinds", extension: "json") else {
            throw ThingsError.resourceMissing("field-kinds.json")
        }
        let registry = try FieldKindRegistry(data: Data(contentsOf: url))
        RegistryCache.shared.value = registry
        return registry
    }

    // MARK: - Lookup

    public func variant(_ id: String?) -> Variant? {
        guard let id else { return nil }
        return variantsByID[id]
    }

    public func variants(ofKind kind: FieldKind) -> [Variant] {
        variantsByKind[kind.rawValue] ?? []
    }

    public func kind(_ kind: FieldKind) -> Kind? {
        kinds[kind.rawValue]
    }

    public var allKinds: [FieldKind] {
        kinds.keys.sorted().map { FieldKind($0) }
    }

    public func template(_ id: String) -> Template? {
        templates.first { $0.id == id }
    }

    public func actions(for variant: Variant) -> [Action] {
        variant.actions.compactMap { actions[$0] }
    }

    /// A `secret` field is always secret regardless of what the row says; other kinds
    /// default to not-secret and the user may override per field.
    public func defaultIsSecret(forVariant id: String?) -> Bool {
        guard let variant = variant(id), let kind = kinds[variant.kind.rawValue] else { return false }
        return kind.isAlwaysSecret
    }

    public func storage(forVariant id: String?) -> FieldStorage? {
        guard let variant = variant(id) else { return nil }
        return kinds[variant.kind.rawValue]?.storage
    }

    /// Picks the most specific `url` variant whose `match` regex hits, e.g.
    /// `https://github.com/x` → `github`. Falls back to `website`.
    public func detectURLVariant(_ urlString: String) -> Variant? {
        let candidates = variants(ofKind: .url)
        for candidate in candidates {
            guard let pattern = candidate.match else { continue }
            if RegexCache.shared.matches(pattern: pattern, in: urlString) {
                return candidate
            }
        }
        return candidates.first { $0.id == "website" } ?? candidates.first
    }

    public func validate(_ value: String, variantID: String?) -> Bool {
        guard let variant = variant(variantID), let pattern = variant.validate else { return true }
        if value.isEmpty { return true }
        return RegexCache.shared.matches(pattern: pattern, in: value)
    }

    /// Marker tokens are stored in the FTS `markers` column, which is tokenised by
    /// unicode61 — and unicode61 splits on `:` and `_`. So `has:password` is indexed as
    /// the single token `haspassword`. Filters are additionally resolved with SQL
    /// predicates, so this is belt-and-braces rather than the primary mechanism.
    public static func indexToken(forMarker marker: String) -> String {
        marker.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}

// MARK: - Caches

final class RegistryCache: @unchecked Sendable {
    static let shared = RegistryCache()
    private let lock = NSLock()
    private var storage: FieldKindRegistry?

    var value: FieldKindRegistry? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var expressions: [String: NSRegularExpression] = [:]

    func matches(pattern: String, in text: String) -> Bool {
        guard let expression = expression(for: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }

    private func expression(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = expressions[pattern] { return cached }
        guard let created = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        expressions[pattern] = created
        return created
    }
}
