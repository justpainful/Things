import SwiftUI
import ThingsCore

/// "2 Versions".
///
/// Only a genuine same-entity collision reaches this screen. Because version vectors live
/// on *fields*, the common case — the phone edits Notes while the computer edits Password —
/// is two different entities and both simply apply. Nothing to choose.
struct ConflictView: View {

    @Environment(AppModel.self) private var model
    @State private var conflicts: [Conflict] = []

    var body: some View {
        Group {
            if conflicts.isEmpty {
                EmptyStateView(symbol: "checkmark.circle",
                               title: "Nothing to resolve",
                               message: "When two devices change the same thing at the same time, both versions show up here and you pick.")
            } else {
                List {
                    ForEach(conflicts) { conflict in
                        Section {
                            versionCard(title: "This iPhone",
                                        json: conflict.versionAJSON,
                                        symbol: "iphone") {
                                resolve(conflict, side: .a)
                            }
                            versionCard(title: "Your computer",
                                        json: conflict.versionBJSON,
                                        symbol: "desktopcomputer") {
                                resolve(conflict, side: .b)
                            }
                        } header: {
                            Text("2 Versions")
                        } footer: {
                            Text("Detected \(RelativeTime.string(fromISO8601: conflict.detectedAt, nowMilliseconds: model.displayNowMilliseconds)). The newer one is shown in the app until you choose.")
                        }
                    }
                }
            }
        }
        .navigationTitle("Conflicts")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Conflict.root)
        .task { load() }
    }

    private func versionCard(title: String, json: String, symbol: String, choose: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
            ForEach(summarise(json)) { pair in
                HStack(alignment: .top) {
                    Text(pair.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Text(pair.value)
                        .font(.callout)
                        .lineLimit(3)
                }
            }
            Button("Keep This One", action: choose)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    /// Human-readable columns only, and never a value that might be a secret.
    private func summarise(_ json: String) -> [ConflictFieldRow] {
        guard let parsed = try? JSONValue.parse(json), let members = parsed.objectValue else { return [] }
        let interesting = ["title", "label", "name", "value_text", "value_cipher", "path", "smart_query"]
        var rows: [ConflictFieldRow] = []
        for key in interesting {
            guard let value = members[key] else { continue }
            if key == "value_cipher" {
                rows.append(ConflictFieldRow(id: "Secret", value: "changed"))
                continue
            }
            if let text = value.stringValue, !text.isEmpty {
                rows.append(ConflictFieldRow(id: key.replacingOccurrences(of: "_", with: " ").capitalized,
                                             value: text))
            }
        }
        return rows
    }

    private func resolve(_ conflict: Conflict, side: ConflictSide) {
        model.perform("Resolve") { library in
            try library.write { db in
                try library.conflicts.resolve(db, conflictID: conflict.id, choosing: side, oplog: library.oplog)
            }
        }
        load()
    }

    private func load() {
        guard let library = model.library else { return }
        conflicts = (try? library.read { db in
            try library.conflicts.openConflicts(db)
        }) ?? []
    }
}

/// One labelled line inside a version card. A struct rather than a tuple because Swift has
/// no key path to a tuple element, and `ForEach` needs an `Identifiable`.
struct ConflictFieldRow: Identifiable, Equatable {
    let id: String
    let value: String
}