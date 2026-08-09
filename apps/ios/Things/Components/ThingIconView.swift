import SwiftUI
import ThingsCore

/// The icon on a Thing.
///
/// `icon_json.type = 'auto'` resolves locally and deterministically — a function of the
/// title and the field kinds present. No AI, no network, and the same input always
/// produces the same icon, which the pixel diff depends on.
struct ThingIconView: View {

    let icon: ThingIcon
    var variants: [String] = []
    var title: String = ""
    var size: CGFloat = Theme.Size.icon
    var registry: FieldKindRegistry?

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                switch icon.kind {
                case .emoji:
                    Text(icon.value ?? "🗂")
                        .font(.system(size: size * 0.52))
                case .symbol:
                    Image(systemName: icon.value ?? "square.stack")
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(tint)
                case .object, .auto:
                    Image(systemName: resolvedSymbol)
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .accessibilityHidden(true)
    }

    private var resolvedSymbol: String {
        guard let registry else { return "square.stack" }
        return ThingIcon.resolveAutomatic(title: title, variants: variants, registry: registry).symbol
    }

    private var tint: Color {
        ThingsPalette.color(named: icon.tint ?? ThingIcon.tintName(for: title))
    }
}

/// The named tints `ThingIcon` produces. Deliberately the system palette rather than a
/// bespoke one — an app that invents its own colours stops looking like part of the system.
enum ThingsPalette {

    static func color(named name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "mint": return .mint
        case "brown": return .brown
        case "gray", "grey": return .gray
        default: return .accentColor
        }
    }
}
