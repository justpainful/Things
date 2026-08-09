import Foundation

/// The query DSL from `docs/01-DATA-MODEL.md` §6.
///
///     tag:1980  type:image  has:password  has:file  collection:1980
///     device:RAEID-PC  modified:this-week  created:2026-08  is:locked  is:pinned
///     "exact phrase"  -excluded  sort:modified  size:>50mb
///
/// Bare text matches everywhere. Operators are sugar the filter chips generate — the user
/// never has to learn them, and the power user never has to leave the keyboard.
public struct SearchQuery: Equatable, Sendable {

    public struct Filter: Equatable, Sendable, Hashable {
        public var key: String
        public var value: String
        public var negated: Bool

        public init(key: String, value: String, negated: Bool = false) {
            self.key = key
            self.value = value
            self.negated = negated
        }

        public var canonical: String {
            "\(negated ? "-" : "")\(key):\(value)"
        }
    }

    /// Keys the parser recognises. Anything else is treated as free text, so a Thing
    /// literally titled "ratio:2" is still findable.
    public static let knownKeys: Set<String> = [
        "tag", "type", "has", "collection", "device", "modified",
        "created", "is", "sort", "size", "kind", "variant"
    ]

    public var terms: [String] = []
    public var phrases: [String] = []
    public var excludedTerms: [String] = []
    public var filters: [Filter] = []

    public init() {}

    public init(terms: [String] = [], phrases: [String] = [], excludedTerms: [String] = [], filters: [Filter] = []) {
        self.terms = terms
        self.phrases = phrases
        self.excludedTerms = excludedTerms
        self.filters = filters
    }

    public var isEmpty: Bool {
        terms.isEmpty && phrases.isEmpty && excludedTerms.isEmpty && filters.isEmpty
    }

    public var hasFreeText: Bool {
        !terms.isEmpty || !phrases.isEmpty
    }

    public func filters(key: String) -> [Filter] {
        filters.filter { $0.key == key }
    }

    /// `sort:` is a filter in the grammar but a mode in the UI.
    public var sortKey: String? {
        filters.first { $0.key == "sort" && !$0.negated }?.value
    }

    // MARK: - Parsing

    public static func parse(_ text: String) -> SearchQuery {
        var query = SearchQuery()
        for token in tokenize(text) {
            switch token {
            case .phrase(let value):
                query.phrases.append(value)
            case .word(let value, let negated):
                if negated {
                    query.excludedTerms.append(value)
                } else {
                    query.terms.append(value)
                }
            case .filter(let key, let value, let negated):
                query.filters.append(Filter(key: key, value: value, negated: negated))
            }
        }
        return query
    }

    enum Token: Equatable {
        case word(String, negated: Bool)
        case phrase(String)
        case filter(key: String, value: String, negated: Bool)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            // Skip whitespace
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }

            var negated = false
            if characters[index] == "-" && index + 1 < characters.count && !characters[index + 1].isWhitespace {
                negated = true
                index += 1
            }

            if index < characters.count, characters[index] == "\"" {
                index += 1
                var phrase = ""
                while index < characters.count, characters[index] != "\"" {
                    phrase.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }        // closing quote
                let trimmed = phrase.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    // A negated phrase becomes an excluded term of the whole phrase.
                    tokens.append(negated ? .word(trimmed, negated: true) : .phrase(trimmed))
                }
                continue
            }

            var raw = ""
            while index < characters.count, !characters[index].isWhitespace {
                // A quote begins the value of `key:"two words"`.
                if characters[index] == "\"" && raw.hasSuffix(":") {
                    index += 1
                    while index < characters.count, characters[index] != "\"" {
                        raw.append(characters[index])
                        index += 1
                    }
                    if index < characters.count { index += 1 }
                    break
                }
                raw.append(characters[index])
                index += 1
            }
            guard !raw.isEmpty else { continue }

            if let colon = raw.firstIndex(of: ":") {
                let key = String(raw[raw.startIndex..<colon]).lowercased()
                let value = String(raw[raw.index(after: colon)...])
                if knownKeys.contains(key) && !value.isEmpty {
                    tokens.append(.filter(key: key, value: value, negated: negated))
                    continue
                }
            }
            tokens.append(.word(raw, negated: negated))
        }
        return tokens
    }

    /// Round-trips to a stable string, which is what a smart collection stores.
    public var canonical: String {
        var parts: [String] = []
        parts.append(contentsOf: filters.map { $0.canonical }.sorted())
        parts.append(contentsOf: phrases.map { "\"\($0)\"" })
        parts.append(contentsOf: terms)
        parts.append(contentsOf: excludedTerms.map { "-\($0)" })
        return parts.joined(separator: " ")
    }
}

/// A relative date filter — `modified:this-week`, `created:2026-08`.
public enum DateFilterRange: Equatable, Sendable {
    case todayOnly
    case lastDays(Int)
    case month(year: Int, month: Int)
    case year(Int)
    case exactDay(String)     // yyyy-MM-dd

    /// Resolved against an injected "now" so the Screenshot Tour is stable.
    public func bounds(nowMilliseconds: Int64) -> (lower: String, upper: String)? {
        let dayMillis = Timestamp.millisecondsPerDay
        switch self {
        case .todayOnly:
            let startOfDay = (nowMilliseconds / dayMillis) * dayMillis
            return (Timestamp.string(millisecondsSinceEpoch: startOfDay),
                    Timestamp.string(millisecondsSinceEpoch: startOfDay + dayMillis))
        case .lastDays(let days):
            let startOfDay = (nowMilliseconds / dayMillis) * dayMillis
            let lower = startOfDay - Int64(days - 1) * dayMillis
            return (Timestamp.string(millisecondsSinceEpoch: lower),
                    Timestamp.string(millisecondsSinceEpoch: startOfDay + dayMillis))
        case .month(let year, let month):
            let start = Timestamp.daysFromCivil(year: Int64(year), month: Int64(month), day: 1) * dayMillis
            let nextMonth = month == 12 ? 1 : month + 1
            let nextYear = month == 12 ? year + 1 : year
            let end = Timestamp.daysFromCivil(year: Int64(nextYear), month: Int64(nextMonth), day: 1) * dayMillis
            return (Timestamp.string(millisecondsSinceEpoch: start), Timestamp.string(millisecondsSinceEpoch: end))
        case .year(let year):
            let start = Timestamp.daysFromCivil(year: Int64(year), month: 1, day: 1) * dayMillis
            let end = Timestamp.daysFromCivil(year: Int64(year + 1), month: 1, day: 1) * dayMillis
            return (Timestamp.string(millisecondsSinceEpoch: start), Timestamp.string(millisecondsSinceEpoch: end))
        case .exactDay(let day):
            guard let start = Timestamp.milliseconds(fromISO8601: day + "T00:00:00.000Z") else { return nil }
            return (Timestamp.string(millisecondsSinceEpoch: start),
                    Timestamp.string(millisecondsSinceEpoch: start + dayMillis))
        }
    }

    public static func parse(_ value: String) -> DateFilterRange? {
        switch value.lowercased() {
        case "today": return .todayOnly
        case "yesterday": return .lastDays(2)
        case "this-week", "week": return .lastDays(7)
        case "this-month", "month": return .lastDays(30)
        case "this-year", "year": return .lastDays(365)
        default:
            break
        }
        let parts = value.split(separator: "-").map(String.init)
        if parts.count == 1, parts[0].count == 4, let year = Int(parts[0]) {
            return .year(year)
        }
        if parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) {
            return .month(year: year, month: month)
        }
        if parts.count == 3, parts[0].count == 4, Int(parts[0]) != nil {
            return .exactDay(value)
        }
        return nil
    }
}

/// `size:>50mb`, `size:<1kb`, `size:>=10mb`.
public struct SizeFilter: Equatable, Sendable {
    public enum Comparison: String, Sendable { case greater = ">", greaterOrEqual = ">=", less = "<", lessOrEqual = "<=", equal = "=" }

    public var comparison: Comparison
    public var bytes: Int64

    public init(comparison: Comparison, bytes: Int64) {
        self.comparison = comparison
        self.bytes = bytes
    }

    public static func parse(_ value: String) -> SizeFilter? {
        var text = value.lowercased()
        var comparison = Comparison.greaterOrEqual
        for candidate in [Comparison.greaterOrEqual, .lessOrEqual, .greater, .less, .equal] where text.hasPrefix(candidate.rawValue) {
            comparison = candidate
            text = String(text.dropFirst(candidate.rawValue.count))
            break
        }
        let multipliers: [(String, Int64)] = [("gb", 1 << 30), ("mb", 1 << 20), ("kb", 1 << 10), ("b", 1)]
        for (suffix, multiplier) in multipliers where text.hasSuffix(suffix) {
            let numberText = String(text.dropLast(suffix.count))
            guard let number = Double(numberText) else { return nil }
            return SizeFilter(comparison: comparison, bytes: Int64(number * Double(multiplier)))
        }
        guard let number = Double(text) else { return nil }
        return SizeFilter(comparison: comparison, bytes: Int64(number))
    }

    public var sqlComparison: String { comparison.rawValue }
}
