import SwiftUI
import UIKit
import ThingsCore

/// Search.
///
/// Bare text matches everywhere. The chips write operators into the same query string the
/// power user can type by hand, so there is exactly one grammar and one parser — the same
/// one the PC uses, held to the same conformance vectors.
struct SearchView: View {

    @Environment(AppModel.self) private var model

    @State private var text = ""
    @State private var activeChips: Set<String> = []
    @State private var hits: [Thing] = []
    @State private var suggestions: [Thing] = []
    @State private var searchFailure: String?

    /// Chips are generated from the registry's smart views so a new one is a JSON change.
    private var chips: [FieldKindRegistry.SmartView] {
        model.registry?.smartViews ?? []
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .navigationDestination(for: Thing.self) { thing in
                    ThingDetailView(thingID: thing.id)
                }
                .navigationDestination(for: HomeRoute.self) { route in
                    RouteDestination(route: route)
                }
                .searchable(text: $text, prompt: "Things, fields, files")
                .accessibilityIdentifier(A11y.Search.root)
        }
        .task { await loadSuggestions() }
        .onChange(of: text) { _, _ in runSearch() }
        .onChange(of: activeChips) { _, _ in runSearch() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            chipsRow

            if let searchFailure {
                EmptyStateView(symbol: "magnifyingglass",
                               title: "Search is unavailable",
                               message: searchFailure)
            } else if text.isEmpty && activeChips.isEmpty {
                idleContent
            } else if hits.isEmpty {
                EmptyStateView(symbol: "magnifyingglass",
                               title: "No matches",
                               message: "Nothing matched \(describeQuery()). Try fewer words, or clear a filter.")
            } else {
                List(hits) { thing in
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
    }

    private var chipsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.tight) {
                ForEach(chips) { chip in
                    let isOn = activeChips.contains(chip.id)
                    Button {
                        if isOn { activeChips.remove(chip.id) } else { activeChips.insert(chip.id) }
                    } label: {
                        Label(chip.name, systemImage: chip.symbol)
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.vertical, Theme.Spacing.tight)
                    }
                    .buttonStyle(.plain)
                    .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                     : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)),
                                in: ThingsShape.rounded(Theme.Radius.chip))
                    .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                    .accessibilityIdentifier(A11y.Search.chip(chip.id))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier(A11y.Search.chips)
    }

    @ViewBuilder
    private var idleContent: some View {
        if suggestions.isEmpty {
            EmptyStateView(symbol: "magnifyingglass",
                           title: "Search everything",
                           message: "Titles, field labels, notes, links, filenames and paths. Secrets are never searched by value.")
        } else {
            List {
                Section("Recent") {
                    ForEach(suggestions) { thing in
                        NavigationLink(value: thing) {
                            ThingRowView(thing: thing,
                                         registry: model.registry,
                                         nowMilliseconds: model.displayNowMilliseconds)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Query

    private func composedQuery() -> String {
        var parts: [String] = []
        for chipID in activeChips.sorted() {
            if let chip = chips.first(where: { $0.id == chipID }) {
                parts.append(chip.query)
            }
        }
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: " ")
    }

    private func describeQuery() -> String {
        let composed = composedQuery()
        return composed.isEmpty ? "that" : "“\(composed)”"
    }

    private func runSearch() {
        guard let library = model.library else { return }
        let composed = composedQuery()
        guard !composed.isEmpty else {
            hits = []
            return
        }
        do {
            let query = SearchQuery.parse(composed)
            hits = try library.read { db in
                let found = try library.search.search(db, query: query)
                guard !found.isEmpty else { return [Thing]() }
                var results: [Thing] = []
                for hit in found {
                    if let thing = try library.things.find(db, id: hit.thingID) {
                        results.append(thing)
                    }
                }
                return results
            }
            searchFailure = nil
        } catch {
            searchFailure = "\(error)"
        }
    }

    private func loadSuggestions() async {
        guard let library = model.library else { return }
        do {
            for try await value in library.things.observeHome() {
                suggestions = value.recent
            }
        } catch {
            model.errorMessage = "Could not load recents. \(error)"
        }
    }
}
