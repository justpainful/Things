import SwiftUI
import ThingsCore

/// Every `HomeRoute` destination, in one place.
///
/// All three tabs register the same set. A `NavigationLink(value:)` whose value has no
/// matching `navigationDestination` in the current stack silently does nothing at run time,
/// and "History does nothing when you reach it from Search" is exactly the kind of defect
/// that survives a screenshot review.
struct RouteDestination: View {

    let route: HomeRoute

    var body: some View {
        switch route {
        case .allThings:
            AllThingsView()
        case .settings:
            SettingsView()
        case .trash:
            TrashView()
        case .history(let thingID):
            HistoryView(thingID: thingID)
        case .conflicts:
            ConflictView()
        case .sync:
            SyncPairingView()
        case .collection(let id):
            CollectionDetailView(collectionID: id)
        }
    }
}

enum HomeRoute: Hashable {
    case allThings
    case settings
    case trash
    case history(thingID: String?)
    case conflicts
    case sync
    case collection(id: String)
}

/// Home — Pinned, Recent, Collections, Suggestions.
///
/// A launchpad, not a dashboard. There are no stat cards here on purpose: "a Dashboard with
/// stat cards" is on the automatic-rejection list.
struct HomeView: View {

    @Environment(AppModel.self) private var model
    @State private var snapshot = HomeSnapshot.empty
    @State private var isPresentingNewThing = false
    @State private var addButtonTapped = 0
    @Namespace private var cardNamespace

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Things")
                .navigationDestination(for: Thing.self) { thing in
                    ThingDetailView(thingID: thing.id, namespace: cardNamespace)
                }
                .navigationDestination(for: HomeRoute.self) { route in
                    RouteDestination(route: route)
                }
                .toolbar {
                    // ToolbarSpacer splits the shared glass background so a symbol and a
                    // word are never merged into what reads as one button.
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: HomeRoute.settings) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityIdentifier(A11y.Home.settingsButton)
                        .accessibilityLabel("Settings")
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            addButtonTapped += 1
                            isPresentingNewThing = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityIdentifier(A11y.Home.addButton)
                        .accessibilityLabel("New Thing")
                    }
                }
                .sheet(isPresented: $isPresentingNewThing) {
                    NewThingSheet()
                }
                .sensoryFeedback(.selection, trigger: addButtonTapped)
                .accessibilityIdentifier(A11y.Home.root)
        }
        .task { await observe() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if snapshot.totalCount == 0 {
            EmptyStateView(
                symbol: "square.stack",
                title: "Nothing here yet",
                message: "Everything you keep lives here — accounts, files, links, notes. Add the first one.",
                actionTitle: "New Thing"
            ) {
                isPresentingNewThing = true
            }
        } else {
            List {
                if !snapshot.pinned.isEmpty {
                    Section("Pinned") {
                        ScrollView(.horizontal) {
                            HStack(spacing: Theme.Spacing.small) {
                                ForEach(snapshot.pinned) { thing in
                                    NavigationLink(value: thing) {
                                        ThingCardView(thing: thing, registry: model.registry)
                                    }
                                    .buttonStyle(.plain)
                                    .matchedTransitionSource(id: thing.id, in: cardNamespace)
                                    .contextMenu { ThingQuickActions(thing: thing) }
                                }
                            }
                            .padding(.vertical, Theme.Spacing.tight)
                        }
                        .scrollIndicators(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.medium,
                                                  bottom: 0, trailing: 0))
                    }
                }

                Section("Recent") {
                    ForEach(snapshot.recent) { thing in
                        NavigationLink(value: thing) {
                            ThingRowView(thing: thing,
                                         registry: model.registry,
                                         nowMilliseconds: model.displayNowMilliseconds)
                        }
                        .matchedTransitionSource(id: thing.id, in: cardNamespace)
                        .contextMenu { ThingQuickActions(thing: thing) }
                    }
                    NavigationLink(value: HomeRoute.allThings) {
                        Label("All Things", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier(A11y.Home.allThingsLink)
                }

                if !snapshot.collections.isEmpty {
                    Section("Collections") {
                        ForEach(snapshot.collections.prefix(5)) { collection in
                            NavigationLink(value: HomeRoute.collection(id: collection.id)) {
                                Label {
                                    Text(collection.name).lineLimit(1)
                                } icon: {
                                    Image(systemName: collection.icon.value ?? "folder")
                                }
                            }
                        }
                    }
                }

                if !snapshot.suggestions.isEmpty {
                    Section {
                        ForEach(snapshot.suggestions) { thing in
                            NavigationLink(value: thing) {
                                ThingRowView(thing: thing,
                                             subtitle: "Added, never opened",
                                             registry: model.registry,
                                             nowMilliseconds: model.displayNowMilliseconds)
                            }
                        }
                    } header: {
                        Text("Suggestions")
                    } footer: {
                        Text("Things you added but have not opened yet.")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Live data

    private func observe() async {
        guard let library = model.library else { return }
        do {
            for try await value in library.things.observeHome() {
                snapshot = value
            }
        } catch {
            model.errorMessage = "Could not load your Things. \(error)"
        }
    }
}

/// The long-press menu. Glass comes from the system context-menu preview — never
/// hand-rolled.
struct ThingQuickActions: View {

    @Environment(AppModel.self) private var model
    let thing: Thing

    var body: some View {
        Button {
            model.perform("Pin") { library in
                try library.write { db in
                    try library.things.setPinned(db, id: thing.id, !thing.isPinned)
                }
            }
        } label: {
            Label(thing.isPinned ? "Unpin" : "Pin", systemImage: thing.isPinned ? "pin.slash" : "pin")
        }

        Button {
            model.perform("Lock") { library in
                try library.write { db in
                    try library.things.setLocked(db, id: thing.id, !thing.isLocked)
                }
            }
        } label: {
            Label(thing.isLocked ? "Unlock" : "Lock", systemImage: thing.isLocked ? "lock.open" : "lock")
        }

        Button {
            model.perform("Duplicate") { library in
                try library.write { db in
                    _ = try library.things.duplicate(db, id: thing.id)
                }
            }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        Divider()

        Button(role: .destructive) {
            model.perform("Delete") { library in
                try library.write { db in
                    try library.things.moveToTrash(db, id: thing.id)
                }
            }
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }
}
