import SwiftUI
import ThingsCore

/// How the ~50 field variants are presented for picking.
///
/// The **grouping** is editorial — Text · Secrets · Links · Files · Numbers & Dates · Other
/// is a judgement about what a person is looking for. The **contents** are not: every group
/// is filled by asking the registry for the kinds it claims, and anything the declared
/// groups do not claim falls into Other in registry order. Adding "Threads" to
/// `spec/field-kinds.json` tomorrow still needs no edit here.
struct FieldTypeSection: Identifiable {
    var id: String
    var title: String
    var variants: [FieldKindRegistry.Variant]
}

enum FieldTypeCatalog {

    private struct Declared {
        var id: String
        var title: String
        var kinds: [String]
    }

    private static let declared: [Declared] = [
        Declared(id: "text",    title: "Text",             kinds: ["text", "longText", "richText"]),
        Declared(id: "secrets", title: "Secrets",          kinds: ["secret"]),
        Declared(id: "links",   title: "Links",            kinds: ["url"]),
        Declared(id: "files",   title: "Files",            kinds: ["attachment", "path"]),
        Declared(id: "numbers", title: "Numbers & Dates",  kinds: ["number", "date", "money"])
    ]

    static func sections(in registry: FieldKindRegistry, matching query: String) -> [FieldTypeSection] {
        var sections: [FieldTypeSection] = []

        for group in declared {
            var variants: [FieldKindRegistry.Variant] = []
            for kindName in group.kinds {
                variants.append(contentsOf: registry.variants(ofKind: FieldKind(kindName)))
            }
            let matched = filter(variants, query: query, groupTitle: group.title)
            if !matched.isEmpty {
                sections.append(FieldTypeSection(id: group.id, title: group.title, variants: matched))
            }
        }

        let claimed = Set(declared.flatMap { $0.kinds })
        let leftovers = registry.variants.filter { !claimed.contains($0.kind.rawValue) }
        let matchedLeftovers = filter(leftovers, query: query, groupTitle: "Other")
        if !matchedLeftovers.isEmpty {
            sections.append(FieldTypeSection(id: "other", title: "Other", variants: matchedLeftovers))
        }

        return sections
    }

    /// Matches the visible label, the registry id, the kind and the group heading, so
    /// "secret", "key", "pass" and "Secrets" all find Password.
    private static func filter(_ variants: [FieldKindRegistry.Variant],
                               query: String,
                               groupTitle: String) -> [FieldKindRegistry.Variant] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return variants }
        if groupTitle.localizedCaseInsensitiveContains(trimmed) { return variants }
        return variants.filter {
            $0.label.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
                || $0.kind.rawValue.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// A one-line hint under the type name on the value step. Plain language, and never a
    /// description of the implementation.
    static func hint(for variant: FieldKindRegistry.Variant) -> String {
        switch variant.kind.rawValue {
        case "secret":     return "Stored encrypted. Never written in the clear."
        case "attachment": return "Kept in Things, encrypted, and deduplicated."
        case "path":       return "A location on a device, not the file itself."
        case "url":        return "A link you can open."
        case "richText",
             "longText":   return "Room for several lines."
        case "date":       return "A day, or a day and a time."
        case "money":      return "An amount and its currency."
        case "geo":        return "A latitude and a longitude."
        case "tagList":    return "Tags for this Thing, separated by commas."
        case "relation":   return "Another Thing in your library."
        case "color":      return "A colour, stored as a hex value."
        case "code":       return "Monospaced, and never autocorrected."
        default:           return "A single line of text."
        }
    }
}

/// One pickable field type. Deliberately roomy: the owner reported touch targets smaller
/// than Apple's, so 44pt is a floor here rather than an aspiration.
struct FieldTypeRow: View {

    let variant: FieldKindRegistry.Variant

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: variant.symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)

            Text(variant.label)
                .font(.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
