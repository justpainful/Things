import SwiftUI
import ThingsCore

/// Collections.
///
/// Membership is many-to-many — one Cloudflare in both `Development` and `1980`, with one
/// copy of the data. Smart collections are saved searches; the only difference the user
/// sees is that they fill themselves.
struct CollectionsView: View {

    @Environment(AppModel.self) private var model
    @State private var collections: [ThingCollection] = []
    @State private var counts: [String: Int] = [:]
    @State private var isPresentingNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if collections.isEmpty {
                    EmptyStateView(symbol: "folder",
                                   title: "No collections yet",
                                   message: "Collections group Things without moving them. One Thing can live in as many as you like.",
                                   actionTitle: "New Collection") {
                        isPresentingNew = true
                    }
                } else {
                    List {
                        let manual = collections.filter { !$0.isSmart }
                        let smart = collections.filter { $0.isSmart }

                        if !manual.isEmpty {
                            Section {
                                ForEach(manual) { collection in
                                    row(collection)
                                }
                            }
                        }
                        if !smart.isEmpty {
                            Section {
                                ForEach(smart) { collection in
                                    row(collection)
                                }
                            } header: {
                                Text("Smart Views")
                            } header: {
                                Text("Collections")
                            } footer: {
                                Text("Smart Views are saved searches. Edit one and it stays yours.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Collections")
            .navigationDestination(for: Thing.self) { thing in
                ThingDetailView(thingID: thing.id)
            }
            .navigationDestination(for: HomeRoute.self) { route in
                RouteDestination(route: route)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Collection")
                }
            }
            .alert("New Collection", isPresented: $isPresentingNew) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") { create() }
            } message: {
                Text("Group Things without moving them.")
            }
            .accessibilityIdentifier(A11y.Collections.root)
        }
        .task { await observe() }
    }

    private func row(_ collection: ThingCollection) -> some View {
        NavigationLink(value: HomeRoute.collection(id: collection.id)) {
            HStack {
                Label {
                    Text(collection.name).lineLimit(1)
                } icon: {
                    Image(systemName: collection.icon.value ?? (collection.isSmart ? "sparkles" : "folder"))
                }
                Spacer()
                Text("\(counts[collection.id] ?? 0)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityIdentifier(A11y.Collections.row(collection.id))
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        model.perform("Create collection") { library in
            try library.write { db in
                _ = try library.collections.create(db, name: name)
            }
        }
    }

    private func observe() async {
        guard let library = model.library else { return }
        do {
            for try await summaries in library.collections.observeSummaries(search: library.search) {
                collections = summaries.map { $0.collection }
                var result: [String: Int] = [:]
                for summary in summaries { result[summary.id] = summary.count }
                counts = result
            }
        } catch {
            model.errorMessage = "Could not load collections. \(error)"
        }
    }
}

struct CollectionDetailView: View {

    @Environment(AppModel.self) private var model

    let collectionID: String

    @State private var collection: ThingCollection?
    @State private var things: [Thing] = []

    var body: some View {
        Group {
            if things.isEmpty {
                EmptyStateView(symbol: "folder",
                               title: "Nothing in here yet",
                               message: collection?.isSmart == true
                                   ? "This Smart View fills itself as soon as something matches."
                                   : "Add Things to this collection from their own screens.")
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
        .navigationTitle(collection?.name ?? "Collection")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Collections.detailRoot)
        .task { await load() }
    }

    private func load() async {
        guard let library = model.library else { return }
        do {
            for try await contents in library.collections.observeMembers(collectionID: collectionID,
                                                                          search: library.search) {
                things = contents.things
                collection = contents.collection
            }
        } catch {
            model.errorMessage = "Could not load this collection. \(error)"
        }
    }
}
