import SwiftUI
import ThingsCore

/// History, grouped by day.
///
/// One table delivers History, Restore, Undo and sync. Secret values inside a change are
/// ciphertext envelopes, so this screen can say *that* a password changed and never what it
/// changed to — which is the difference between a history feature and a plaintext password
/// log.
struct HistoryView: View {

    @Environment(AppModel.self) private var model

    /// `nil` = the whole library.
    let thingID: String?

    @State private var groups: [HistoryGroup] = []

    var body: some View {
        Group {
            if groups.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath",
                               title: "No history yet",
                               message: "Every change you make is recorded here, and any of them can be put back.")
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.heading) {
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry, onRestore: { restore(entry) })
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.History.root)
        .task { load() }
    }

    private func load() {
        guard let library = model.library else { return }
        let changes = (try? library.read { db -> [Change] in
            if let thingID {
                return try library.oplog.history(db, thingID: thingID)
            }
            return try Change.fetchAll(db, sql: "SELECT * FROM change ORDER BY hlc DESC LIMIT 200")
        }) ?? []
        groups = HistoryGroup.build(from: changes, nowMilliseconds: model.displayNowMilliseconds)
    }

    private func restore(_ entry: HistoryEntry) {
        model.perform("Restore") { library in
            // `_ =` is load-bearing. `restore` returns the new Change, and a single-expression
            // closure infers its return type from that — so the closure becomes
            // `(Database) -> Change` while `perform` requires `-> Void`, and the generic
            // parameter conflicts. Discarding makes the closure Void.
            try library.write { db in
                _ = try library.oplog.restore(db, changeID: entry.id)
            }
        }
        load()
    }
}

struct HistoryEntry: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var time: String
    var canRestore: Bool
}

struct HistoryGroup: Identifiable, Equatable {
    var id: String { heading }
    var heading: String
    var entries: [HistoryEntry]

    static func build(from changes: [Change], nowMilliseconds: Int64) -> [HistoryGroup] {
        var order: [String] = []
        var buckets: [String: [HistoryEntry]] = [:]

        for change in changes {
            let heading = RelativeTime.dayHeading(change.appliedAt, nowMilliseconds: nowMilliseconds)
            if buckets[heading] == nil {
                buckets[heading] = []
                order.append(heading)
            }
            buckets[heading]?.append(entry(for: change, nowMilliseconds: nowMilliseconds))
        }
        return order.map { HistoryGroup(heading: $0, entries: buckets[$0] ?? []) }
    }

    private static func entry(for change: Change, nowMilliseconds: Int64) -> HistoryEntry {
        let attributes = change.attributes.objectValue ?? [:]
        let entityName: String
        switch change.entity {
        case .thing: entityName = "Thing"
        case .field: entityName = "field"
        case .section: entityName = "section"
        case .collection: entityName = "collection"
        case .tag: entityName = "tag"
        case .member: entityName = "collection membership"
        case .thingTag: entityName = "tag"
        case .fileRef: entityName = "file reference"
        case .none: entityName = "record"
        }

        let verb: String
        switch change.operation {
        case .create: verb = "Added"
        case .update: verb = "Changed"
        case .delete: verb = "Deleted"
        case .none: verb = "Touched"
        }

        // Never render a value that might be a secret. `value_cipher` is base64 of an
        // AES-GCM envelope; naming the column is enough.
        var described: [String] = []
        for key in attributes.keys.sorted() where !["updated_at", "version_vector"].contains(key) {
            switch key {
            case "value_cipher": described.append("secret value")
            case "value_text", "value_json": described.append("value")
            case "title", "label", "name": described.append("name")
            case "deleted_at": described.append("trash")
            case "is_pinned": described.append("pin")
            case "is_locked": described.append("lock")
            default: described.append(key.replacingOccurrences(of: "_", with: " "))
            }
        }
        let summary = described.isEmpty ? entityName : described.prefix(3).joined(separator: ", ")

        return HistoryEntry(
            id: change.id,
            title: "\(verb) \(entityName)",
            detail: summary,
            time: RelativeTime.string(fromISO8601: change.appliedAt, nowMilliseconds: nowMilliseconds),
            canRestore: change.prevJSON != nil && change.operation == .update
        )
    }
}

struct HistoryRow: View {

    let entry: HistoryEntry
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.body)
                Text(entry.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.tight)
            VStack(alignment: .trailing, spacing: Theme.Spacing.tight) {
                Text(entry.time).font(.caption).foregroundStyle(.secondary)
                if entry.canRestore {
                    Button("Restore", action: onRestore)
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.hairline)
    }
}
