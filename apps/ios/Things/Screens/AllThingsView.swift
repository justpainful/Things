import SwiftUI
import ThingsCore

/// Every Thing, alphabetical, with an index-friendly plain list.
struct AllThingsView: View {

    @Environment(AppModel.self) private var model
    @State private var things: [Thing] = []

    var body: some View {
        Group {
            if things.isEmpty {
                EmptyStateView(symbol: "tray",
                               title: "No Things yet",
                               message: "Anything you add will show up here.")
            } else {
                List(things) { thing in
                    NavigationLink(value: thing) {
                        ThingRowView(thing: thing,
                                     registry: model.registry,
                                     nowMilliseconds: model.displayNowMilliseconds)
                    }
                    .contextMenu { ThingQuickActions(thing: thing) }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("All Things")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.AllThings.root)
        .task { await observe() }
    }

    private func observe() async {
        guard let library = model.library else { return }
        do {
            for try await value in library.things.observeAll() {
                things = value
            }
        } catch {
            model.errorMessage = "Could not load your Things. \(error)"
        }
    }
}
