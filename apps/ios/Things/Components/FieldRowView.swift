import SwiftUI
import UIKit
import ThingsCore

/// One field cell in a Thing's detail.
///
/// This is content, so there is no glass here. The glass in this screen belongs to the
/// navigation bar and the floating actions above it.
struct FieldRowView: View {

    let field: Field
    let detail: ThingDetail
    let registry: FieldKindRegistry
    let privacyMode: Bool
    var revealedValue: String?
    var onReveal: (() -> Void)?
    var onCopy: ((String) -> Void)?

    private var variant: FieldKindRegistry.Variant? {
        registry.variant(field.variant)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: variant?.symbol ?? "textformat")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                valueView
            }

            Spacer(minLength: 0)

            if field.isSecret {
                Button {
                    onReveal?()
                } label: {
                    Image(systemName: revealedValue == nil ? "eye" : "eye.slash")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(revealedValue == nil ? "Reveal" : "Hide")
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .accessibilityIdentifier(A11y.Detail.field(field.id))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Value

    @ViewBuilder
    private var valueView: some View {
        switch field.kind {
        case .boolean:
            Label(field.valueText == "1" ? "Yes" : "No",
                  systemImage: field.valueText == "1" ? "checkmark.circle.fill" : "circle")
                .labelStyle(.titleAndIcon)
                .font(.body)

        case .color:
            HStack(spacing: Theme.Spacing.tight) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: field.valueText ?? "#888888"))
                    .frame(width: 18, height: 18)
                Text(field.valueText ?? "—").font(.body.monospaced())
            }

        case .code:
            Text(displayText)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)

        case .attachment:
            attachmentView

        case .path:
            pathView

        case .relation:
            relationView

        case .richText, .longText:
            Text(displayText)
                .font(.body)
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)

        default:
            Text(displayText)
                .font(.body)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var attachmentView: some View {
        if let hash = field.objectHash, let object = detail.objects[hash] {
            VStack(alignment: .leading, spacing: 1) {
                Text(field.filename ?? "Attached file").font(.body).lineLimit(1)
                Text("\(object.mimeType ?? "File") · \(ByteSize.string(object.byteSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let refID = field.fileRefID, let ref = detail.fileRefs[refID] {
            fileReferenceView(ref)
        } else {
            Text("Not on this iPhone")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pathView: some View {
        if let refID = field.fileRefID, let ref = detail.fileRefs[refID] {
            fileReferenceView(ref)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func fileReferenceView(_ ref: FileRef) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ref.path)
                .font(.callout.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: Theme.Spacing.tight) {
                if ref.statusValue == .missing {
                    Label("Missing", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(deviceName(ref.deviceID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var relationView: some View {
        if let targetID = field.valueText,
           let target = detail.backlinks.first(where: { $0.id == targetID }) {
            Label(target.title, systemImage: "link").font(.body)
        } else if let targetID = field.valueText, !targetID.isEmpty {
            Label("Related Thing", systemImage: "link").font(.body)
                .accessibilityValue(targetID)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func deviceName(_ deviceID: String) -> String {
        // The seed and the real library both keep the self device row, so the common case
        // resolves; anything else shows the raw id rather than pretending.
        deviceID
    }

    // MARK: - Text

    private var displayText: String {
        if field.isSecret {
            if let revealedValue { return revealedValue }
            return String(repeating: "•", count: 12)
        }
        if privacyMode && isPrivate {
            return String(repeating: "•", count: 10)
        }
        if let text = field.valueText, !text.isEmpty { return text }
        if let json = field.valueJSON {
            switch field.kind {
            case .money:
                let parsed = try? JSONValue.parse(json)
                let amount = parsed?["amount"]?.stringValue ?? "0"
                let currency = parsed?["currency"]?.stringValue ?? ""
                return "\(amount) \(currency)".trimmingCharacters(in: .whitespaces)
            case .geo:
                let parsed = try? JSONValue.parse(json)
                let latitude: String = FieldRowView.scalar(parsed, "lat")
                let longitude: String = FieldRowView.scalar(parsed, "lon")
                return "\(latitude), \(longitude)"
            case .richText:
                return SearchIndexer.plainText(fromRichTextJSON: json)
            default:
                return json
            }
        }
        return "—"
    }

    /// Pulls a scalar out of a parsed JSON value as text, whether it was written as a
    /// string or a number.
    private static func scalar(_ value: JSONValue?, _ key: String) -> String {
        guard let member = value?[key] else { return "0" }
        if let text = member.stringValue { return text }
        if case .number(let text) = member { return text }
        return "0"
    }

    /// Privacy Mode masks secrets, emails, phones and keys. It is a display state, not a
    /// security boundary, and the UI does not imply otherwise.
    private var isPrivate: Bool {
        if field.isSecret { return true }
        guard let variant else { return false }
        return ["email", "phone", "username", "ip", "reference"].contains(variant.id)
    }
}

extension Color {

    /// `#RRGGBB`, the only form the `color` kind stores.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
