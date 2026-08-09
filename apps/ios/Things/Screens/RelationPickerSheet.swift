import SwiftUI
import ThingsCore

/// Picks the Thing a `relation` field points at.
///
/// A relation stores a target id in `value_text`, so this is a value editor like any
/// other — it just cannot be typed. The list is every Thing in the library except this
/// one; a Thing that referred to itself would show up in its own "Referenced By".
struct RelationPickerSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let excluding: String
    let currentTargetID: String?
    let onSelect: (String?) -> Void

    @State private var query = ""
    @State private var things: [Thing] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "None", symbol: "minus.circle", isSelected: !hasTarget) {
                        onSelect(nil)
                        dismiss()
                    }
                }

                Section {
                    if matches.isEmpty {
                        InlineEmptyView(message: "Nothing else to link to yet.")
                    } else {
                        ForEach(matches) { thing in
                            Button {
                                onSelect(thing.id)
                                dismiss()
                            } label: {
                                HStack(spacing: Theme.Spacing.small) {
                                    ThingRowView(thing: thing,
                                                 registry: model.registry,
                                                 nowMilliseconds: model.displayNowMilliseconds)
                                    if thing.id == currentTargetID {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("relationPicker.\(thing.id)")
                        }
                    }
                }
            }
            .navigationTitle("Related Thing")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Things")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .accessibilityIdentifier(A11y.Sheets.relationPicker)
        }
        .presentationDetents([.medium, .large])
        .task { load() }
    }

    private var hasTarget: Bool {
        guard let currentTargetID else { return false }
        return !currentTargetID.isEmpty
    }

    private var matches: [Thing] {
        let pool = things.filter { $0.id != excluding }
        guard !query.isEmpty else { return pool }
        return pool.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func row(title: String,
                     symbol: String,
                     isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func load() {
        guard let library = model.library else { return }
        things = (try? library.read { db in try library.things.all(db) }) ?? []
    }
}
