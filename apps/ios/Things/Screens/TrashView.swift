import SwiftUI
import ThingsCore

/// Recently Deleted.
///
/// Soft delete with a retention window. Things never wipes anything on its own timetable
/// that the user has not seen — the sweep runs at launch and only on rows past the window.
struct TrashView: View {

    @Environment(AppModel.self) private var model
    @State private var things: [Thing] = []
    @State private var isConfirmingEmpty = false

    var body: some View {
        Group {
            if things.isEmpty {
                EmptyStateView(symbol: "trash",
                               title: "Nothing deleted",
                               message: "Things you delete stay here for 30 days, so a mistake is never final.")
            } else {
                List {
                    Section {
                        ForEach(things) { thing in
                            HStack {
                                ThingRowView(thing: thing,
                                             subtitle: "Deleted \(RelativeTime.string(fromISO8601: thing.deletedAt, nowMilliseconds: model.displayNowMilliseconds))",
                                             registry: model.registry,
                                             nowMilliseconds: model.displayNowMilliseconds)
                                Spacer(minLength: 0)
                                Button("Put Back") { restore(thing) }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                            }
                        }
                    } footer: {
                        Text("Deleted Things are removed for good after 30 days.")
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !things.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Empty", role: .destructive) { isConfirmingEmpty = true }
                }
            }
        }
        .confirmationDialog("Delete everything in Recently Deleted?",
                            isPresented: $isConfirmingEmpty,
                            titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) { emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .accessibilityIdentifier(A11y.Trash.root)
        .task { await observe() }
    }

    private func restore(_ thing: Thing) {
        model.perform("Put back") { library in
            try library.write { db in
                try library.things.restoreFromTrash(db, id: thing.id)
            }
        }
    }

    private func emptyTrash() {
        model.perform("Empty Recently Deleted") { library in
            try library.write { db in
                try library.things.emptyTrash(db)
            }
        }
    }

    private func observe() async {
        guard let library = model.library else { return }
        do {
            for try await value in library.things.observeTrash() {
                things = value
            }
        } catch {
            model.errorMessage = "Could not load Recently Deleted. \(error)"
        }
    }
}
