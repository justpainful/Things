import SwiftUI
import UIKit
import ThingsCore

/// A Thing: sections, fields, media, relations.
///
/// The body is content, so nothing here is glass. The glass on this screen is the
/// navigation bar's, which the system provides, plus the context-menu previews.
struct ThingDetailView: View {

    @Environment(AppModel.self) private var model

    let thingID: String
    var namespace: Namespace.ID?

    @State private var detail: ThingDetail?
    /// Set once the observation has delivered anything at all — including `nil`.
    ///
    /// Without this, "still loading", "this Thing does not exist", and "the query threw"
    /// are the same picture: a spinner that never stops. The first real screenshot run
    /// photographed exactly that, and it was undiagnosable from the image.
    @State private var didReceiveValue = false
    @State private var loadError: String?
    @State private var revealed: [String: String] = [:]
    @State private var isPresentingAddField = false
    @State private var isPresentingGallery = false
    @State private var copyFeedback = 0
    @State private var toast: String?

    var body: some View {
        Group {
            if let detail {
                if detail.thing.isLocked && !model.configuration.isUITesting {
                    lockedPlaceholder
                } else {
                    content(for: detail)
                }
            } else if let loadError {
                EmptyStateView(symbol: "exclamationmark.triangle",
                               title: "Couldn't open this Thing",
                               message: loadError)
                    .accessibilityIdentifier(A11y.Detail.loadFailed)
            } else if didReceiveValue {
                EmptyStateView(symbol: "questionmark.square.dashed",
                               title: "Not found",
                               message: "This Thing is no longer in your library.")
                    .accessibilityIdentifier(A11y.Detail.notFound)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(detail?.thing.title ?? "")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbar }
        .sheet(isPresented: $isPresentingAddField) {
            AddFieldSheet(thingID: thingID)
        }
        .navigationDestination(isPresented: $isPresentingGallery) {
            MediaGalleryView(thingID: thingID)
        }
        .overlay(alignment: .bottom) { toastView }
        .sensoryFeedback(.success, trigger: copyFeedback)
        .accessibilityIdentifier(A11y.Detail.root)
        .task { await observe() }
        .applyZoomTransition(id: thingID, namespace: namespace)
    }

    // MARK: - Body

    @ViewBuilder
    private func content(for detail: ThingDetail) -> some View {
        List {
            if !detail.tags.isEmpty || !detail.collections.isEmpty {
                Section {
                    ChipsRow(tags: detail.tags.map { $0.name },
                             collections: detail.collections.map { $0.name })
                }
            }

            let galleryFields = model.registry.map { detail.galleryFields(registry: $0) } ?? []
            if !galleryFields.isEmpty {
                Section("Media") {
                    Button {
                        isPresentingGallery = true
                    } label: {
                        Label("\(galleryFields.count) items", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier(A11y.Detail.galleryButton)
                }
            }

            // The unnamed default section first, then named sections in sort order.
            let defaultFields = detail.fields(inSection: nil).filter { !isGallery($0, detail: detail) }
            if !defaultFields.isEmpty {
                Section {
                    ForEach(defaultFields) { field in
                        fieldRow(field, detail: detail)
                    }
                }
            }

            ForEach(detail.sections) { section in
                let fields = detail.fields(inSection: section.id).filter { !isGallery($0, detail: detail) }
                Section(section.title ?? "More") {
                    if fields.isEmpty {
                        InlineEmptyView(message: "Nothing in this section yet.")
                    } else {
                        ForEach(fields) { field in
                            fieldRow(field, detail: detail)
                        }
                    }
                }
            }

            if !detail.backlinks.isEmpty {
                Section("Referenced By") {
                    ForEach(detail.backlinks) { thing in
                        NavigationLink(value: thing) {
                            ThingRowView(thing: thing,
                                         registry: model.registry,
                                         nowMilliseconds: model.displayNowMilliseconds)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Added", value: RelativeTime.absoluteDay(detail.thing.createdAt))
                LabeledContent("Last changed",
                               value: RelativeTime.string(fromISO8601: detail.thing.updatedAt,
                                                          nowMilliseconds: model.displayNowMilliseconds))
                NavigationLink(value: HomeRoute.history(thingID: detail.thing.id)) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier(A11y.Detail.historyButton)
            }

            if detail.fields.isEmpty {
                Section {
                    InlineEmptyView(message: "This Thing has no fields yet. Add one to get started.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func fieldRow(_ field: Field, detail: ThingDetail) -> some View {
        if let registry = model.registry {
            FieldRowView(
                field: field,
                detail: detail,
                registry: registry,
                privacyMode: model.privacyMode,
                revealedValue: revealed[field.id],
                onReveal: { toggleReveal(field) }
            )
            .contextMenu {
                FieldQuickActions(field: field,
                                  detail: detail,
                                  registry: registry,
                                  onCopy: { copy($0) },
                                  onReveal: { toggleReveal(field) },
                                  onDelete: { deleteField(field) })
            }
        }
    }

    private var lockedPlaceholder: some View {
        EmptyStateView(symbol: "lock.fill",
                       title: "Locked",
                       message: "This Thing is hidden until you unlock it. Locked Things never appear in search or previews.")
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            // The one small glass surface on this screen: a floating confirmation above
            // content, which is exactly where glass belongs.
            Text(toast)
                .font(.subheadline)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .thingsGlass(cornerRadius: Theme.Radius.chip)
                .padding(.bottom, Theme.Spacing.large)
                .transition(.opacity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let detail {
                    ThingQuickActions(thing: detail.thing)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityIdentifier(A11y.Detail.moreButton)
            .accessibilityLabel("More")
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingAddField = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier(A11y.Detail.addFieldButton)
            .accessibilityLabel("Add Field")
        }
    }

    // MARK: - Actions

    private func isGallery(_ field: Field, detail: ThingDetail) -> Bool {
        model.registry?.variant(field.variant)?.showsInGallery == true
    }

    private func toggleReveal(_ field: Field) {
        if revealed[field.id] != nil {
            revealed[field.id] = nil
            return
        }
        // In production this is where an optional second Face ID gate sits. The reveal
        // re-hides on a timeout, which the caller drives.
        revealed[field.id] = model.revealSecret(fieldID: field.id) ?? ""
    }

    private func copy(_ value: String) {
        Clipboard.copy(value)
        copyFeedback += 1
        toast = "Copied"
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            toast = nil
        }
    }

    private func deleteField(_ field: Field) {
        model.perform("Delete field") { library in
            try library.write { db in
                try library.fields.deleteField(db, fieldID: field.id)
            }
        }
    }

    private func observe() async {
        guard let library = model.library else { return }
        model.perform { library in
            try library.write { db in
                try library.things.markViewed(db, id: thingID)
            }
        }
        do {
            for try await value in library.things.observeDetail(id: thingID) {
                detail = value
                didReceiveValue = true
            }
        } catch {
            // Shown ON THIS SCREEN, not only routed to a global alert. A detail screen that
            // spins forever while the error is announced somewhere else is the same bug.
            loadError = String(describing: error)
            didReceiveValue = true
            model.errorMessage = "Could not load this Thing. \(error)"
        }
    }
}

/// Tags and collections as chips. Not glass — they sit in content.
struct ChipsRow: View {

    let tags: [String]
    let collections: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.tight) {
                ForEach(collections, id: \.self) { name in
                    chip(name, symbol: "folder")
                }
                ForEach(tags, id: \.self) { name in
                    chip(name, symbol: "tag")
                }
            }
            .padding(.vertical, Theme.Spacing.hairline)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(Color(uiColor: .tertiarySystemFill),
                        in: ThingsShape.rounded(Theme.Radius.chip))
    }
}

/// Per-variant quick actions, driven entirely by `field-kinds.json`.
///
/// Nothing here knows what a "password" is: the action list, its labels and whether it is
/// gated all come from the registry.
struct FieldQuickActions: View {

    let field: Field
    let detail: ThingDetail
    let registry: FieldKindRegistry
    let onCopy: (String) -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let variant = registry.variant(field.variant)
        let actions = variant.map { registry.actions(for: $0) } ?? []

        ForEach(actions) { action in
            Button {
                run(action)
            } label: {
                Label(action.label, systemImage: symbol(for: action))
            }
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("Delete Field", systemImage: "trash")
        }
    }

    private func symbol(for action: FieldKindRegistry.Action) -> String {
        switch action.id {
        case "copy": return "doc.on.doc"
        case "reveal": return "eye"
        case "open": return "safari"
        case "copyLink": return "link"
        case "openInExplorer": return "folder"
        case "copyPath": return "text.line.first.and.arrowtriangle.forward"
        case "sendEmail": return "envelope"
        case "call": return "phone"
        case "quickLook": return "eye.circle"
        case "saveToFiles": return "square.and.arrow.down"
        case "openThing": return "arrow.up.forward.square"
        default: return "ellipsis"
        }
    }

    private func run(_ action: FieldKindRegistry.Action) {
        switch action.id {
        case "reveal":
            onReveal()
        case "copy", "copyLink":
            if let value = field.valueText { onCopy(value) }
        case "copyPath":
            if let refID = field.fileRefID, let ref = detail.fileRefs[refID] { onCopy(ref.path) }
        case "open":
            if let value = field.valueText, let url = URL(string: value) {
                Opener.open(url)
            }
        case "sendEmail":
            if let value = field.valueText, let url = URL(string: "mailto:\(value)") {
                Opener.open(url)
            }
        case "call":
            if let value = field.valueText,
               let url = URL(string: "tel:\(value.filter { $0.isNumber || $0 == "+" })") {
                Opener.open(url)
            }
        default:
            // `openInExplorer` is device-scoped and belongs to the PC; on iPhone the
            // affordance is Copy Path, which is already in the list.
            break
        }
    }
}

extension View {
    /// Isolated so the zoom transition can be removed in one edit if it ever misbehaves in
    /// the Screenshot Tour.
    @ViewBuilder
    func applyZoomTransition(id: String, namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
