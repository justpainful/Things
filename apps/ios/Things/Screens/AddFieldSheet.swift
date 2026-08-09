import SwiftUI
import ThingsCore

/// Add Field.
///
/// The list is generated from `spec/field-kinds.json` at run time. Adding "Threads"
/// tomorrow is a one-line JSON change and this screen picks it up with no edit.
///
/// No custom background on the sheet: a custom `presentationBackground` fights the system
/// glass, and the standard sheet material is already correct.
struct AddFieldSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let thingID: String

    @State private var query = ""
    @State private var selected: String?
    @State private var label = ""
    @State private var value = ""

    private var registry: FieldKindRegistry? { model.registry }

    var body: some View {
        NavigationStack {
            Group {
                if let registry {
                    listContent(registry)
                } else {
                    EmptyStateView(symbol: "exclamationmark.triangle",
                                   title: "Field types unavailable",
                                   message: "Things could not read its field registry.")
                }
            }
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(selected == nil)
                }
            }
            .searchable(text: $query, prompt: "Field type")
            .accessibilityIdentifier(A11y.Sheets.addField)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func listContent(_ registry: FieldKindRegistry) -> some View {
        List {
            if let selected, let variant = registry.variant(selected) {
                Section("Details") {
                    TextField("Label", text: $label, prompt: Text(variant.label))
                    if variant.kind != .secret && variant.kind != .attachment && variant.kind != .path {
                        TextField("Value", text: $value, axis: .vertical)
                            .lineLimit(1...4)
                    } else if variant.kind == .secret {
                        SecureField("Value", text: $value)
                    }
                }
            }

            ForEach(groupedKinds(registry), id: \.self) { kind in
                let variants = matching(registry.variants(ofKind: kind))
                if !variants.isEmpty {
                    Section(kindTitle(kind)) {
                        ForEach(variants) { variant in
                            Button {
                                selected = variant.id
                                if label.isEmpty { label = variant.label }
                            } label: {
                                HStack {
                                    Label(variant.label, systemImage: variant.symbol)
                                    Spacer()
                                    if selected == variant.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("addField.\(variant.id)")
                        }
                    }
                }
            }
        }
    }

    private func groupedKinds(_ registry: FieldKindRegistry) -> [FieldKind] {
        // Registry order, deduplicated — never a hardcoded list.
        var seen: [String] = []
        for variant in registry.variants where !seen.contains(variant.kind.rawValue) {
            seen.append(variant.kind.rawValue)
        }
        return seen.map { FieldKind($0) }
    }

    private func matching(_ variants: [FieldKindRegistry.Variant]) -> [FieldKindRegistry.Variant] {
        guard !query.isEmpty else { return variants }
        return variants.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    private func kindTitle(_ kind: FieldKind) -> String {
        switch kind.rawValue {
        case "text": return "Text"
        case "longText": return "Long Text"
        case "richText": return "Notes"
        case "number": return "Numbers"
        case "boolean": return "Yes / No"
        case "date": return "Dates"
        case "url": return "Links"
        case "path": return "Paths"
        case "secret": return "Secrets"
        case "attachment": return "Files"
        case "color": return "Colour"
        case "code": return "Code"
        case "geo": return "Places"
        case "money": return "Amounts"
        case "relation": return "Related Things"
        case "tagList": return "Tags"
        default: return kind.rawValue
        }
    }

    private func add() {
        guard let selected, let registry, let variant = registry.variant(selected) else { return }
        let finalLabel = label.isEmpty ? variant.label : label
        let entered = value

        model.perform("Add field") { library in
            try library.write { db in
                if variant.kind == .secret {
                    let field = try library.fields.addField(db, thingID: thingID,
                                                            variantID: selected, label: finalLabel)
                    if !entered.isEmpty {
                        try library.fields.setSecret(db, fieldID: field.id,
                                                     plaintext: entered, dek: library.dek)
                    }
                } else {
                    try library.fields.addField(db, thingID: thingID,
                                                variantID: selected,
                                                label: finalLabel,
                                                valueText: entered.isEmpty ? nil : entered)
                }
            }
        }
        dismiss()
    }
}
