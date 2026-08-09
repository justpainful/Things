import SwiftUI
import UIKit
import ThingsCore

/// A Thing: sections, fields, media, relations — and the one screen where all of it can
/// actually be *changed*.
///
/// The body is content, so nothing here is glass. The glass on this screen is the
/// navigation bar's, which the system provides, plus the context-menu previews.
///
/// ## Editing
///
/// Editing is **inline**, in the row, not behind a per-field sheet. A sheet was the
/// standing fallback if inline editing fought the `List`; it did not, because the two
/// things that usually cause that fight are avoided outright:
///
///  * **One draft, owned here.** `editingFieldID` and `draft` live on this screen rather
///    than in each row, so the live query refreshing mid-edit cannot discard what was
///    typed, and two rows can never both think they are being edited.
///  * **Commits carry the field id.** A row being torn down calls back with its own id;
///    if the screen has already moved on, the commit is dropped instead of writing one
///    field's text into another.
///
/// Every write goes through `AppModel.perform` → `library.write` → a repository, so each
/// one lands in the oplog and History, Undo and Restore keep working.
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

    // MARK: Editing state
    //
    // Deliberately one of each: only one field is editable at a time, which is what makes
    // "commit the previous one, then open the next" a two-line operation instead of a
    // reconciliation problem.

    @State private var editingFieldID: String?
    @State private var draft = ""
    /// Which field `draft` belongs to. Deliberately outlives `editingFieldID`: tapping
    /// Expand may blur the inline field first, and without this the full-height editor
    /// would open on the row's last *saved* text and quietly drop the unsaved edit.
    @State private var draftFieldID: String?
    /// Separate from `draft` so the full-height editor keeps its text even though opening
    /// it blurs — and therefore commits and clears — the inline field it came from.
    @State private var noteDraft = ""
    @State private var noteEditorField: Field?
    @State private var relationField: Field?
    @State private var isPresentingRename = false
    @State private var titleDraft = ""
    @State private var editMode: EditMode = .inactive
    /// Titles of every Thing, for resolving a forward `relation`. `detail.backlinks` holds
    /// the things pointing *at* this one, which is the opposite direction.
    @State private var thingTitles: [String: String] = [:]

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
        .sheet(item: $noteEditorField) { field in
            NoteEditorSheet(title: field.label,
                            initialText: noteDraft,
                            isMonospaced: field.kind == .code) { text in
                write(field, text)
            }
        }
        .sheet(item: $relationField) { field in
            RelationPickerSheet(excluding: thingID,
                                currentTargetID: field.valueText) { targetID in
                writeText(field, targetID)
            }
        }
        .alert("Rename", isPresented: $isPresentingRename) {
            TextField("Name", text: $titleDraft)
                .accessibilityIdentifier(A11y.Detail.renameTextField)
            Button("Cancel", role: .cancel) { }
            Button("Rename") { commitRename() }
        } message: {
            Text("Give this Thing a new name.")
        }
        .navigationDestination(isPresented: $isPresentingGallery) {
            MediaGalleryView(thingID: thingID)
        }
        .overlay(alignment: .bottom) { toastView }
        .sensoryFeedback(.success, trigger: copyFeedback)
        .accessibilityIdentifier(A11y.Detail.root)
        .task {
            loadThingTitles()
            await observe()
        }
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
                    .frame(minHeight: 44)
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
                    .onMove { indices, destination in
                        moveFields(defaultFields, sectionID: nil, from: indices, to: destination)
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
                        .onMove { indices, destination in
                            moveFields(fields, sectionID: section.id, from: indices, to: destination)
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
                .frame(minHeight: 44)
                .accessibilityIdentifier(A11y.Detail.historyButton)
            }

            if detail.fields.isEmpty {
                Section {
                    InlineEmptyView(message: "This Thing has no fields yet. Add one to get started.")
                }
            }
        }
        .listStyle(.insetGrouped)
        // Drag the list to put the keyboard away. The blur commits, so a swipe down is a
        // save rather than a discard.
        .scrollDismissesKeyboard(.interactively)
        .environment(\.editMode, $editMode)
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
                onReveal: { toggleReveal(field) },
                relationTitle: relationTitle(for: field),
                nowMilliseconds: model.displayNowMilliseconds,
                isEditing: editingFieldID == field.id,
                draft: $draft,
                onBeginEditing: { beginEditing(field) },
                onCommit: { commitEdit($0) },
                onWriteText: { writeText(field, $0) },
                onPickRelation: { openRelationPicker(field) },
                onExpandEditor: { openNoteEditor(field) }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteField(field)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier(A11y.Detail.fieldDelete(field.id))
            }
            .contextMenu {
                FieldQuickActions(field: field,
                                  detail: detail,
                                  registry: registry,
                                  onCopy: { copy($0) },
                                  onReveal: { toggleReveal(field) },
                                  onEdit: { beginEditing(field) },
                                  onExpand: { openNoteEditor(field) },
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
                Button {
                    titleDraft = detail?.thing.title ?? ""
                    isPresentingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier(A11y.Detail.renameButton)

                Button {
                    commitEdit()
                    editMode = editMode == .active ? .inactive : .active
                } label: {
                    Label(editMode == .active ? "Done Reordering" : "Reorder Fields",
                          systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier(A11y.Detail.reorderButton)

                Divider()

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
        // The numeric and decimal keyboards have no return key, so without this there is
        // no way to finish editing a Port or an Amount except by tapping something else.
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { commitEdit() }
                .accessibilityIdentifier(A11y.Detail.doneEditing)
        }
    }

    // MARK: - Editing

    private func beginEditing(_ field: Field) {
        guard editingFieldID != field.id else { return }
        if let open = editingFieldID {
            commitEdit(open)
        }
        draft = plainText(of: field)
        draftFieldID = field.id
        editingFieldID = field.id
    }

    /// Writes the draft back to the field that is currently open.
    ///
    /// - Parameter expected: the id the *caller* believes it is committing. A row that has
    ///   already been replaced still gets one last callback as its editor is torn down;
    ///   without this check that callback would write the outgoing row's draft into the
    ///   incoming row's field.
    private func commitEdit(_ expected: String? = nil) {
        guard let open = editingFieldID else { return }
        if let expected, expected != open { return }
        editingFieldID = nil
        let value = draft
        guard let field = detail?.fields.first(where: { $0.id == open }) else { return }
        // Never leave a plaintext secret sitting in view state longer than the edit itself.
        if field.isSecret || field.kind == .secret {
            draft = ""
            draftFieldID = nil
        }
        write(field, value)
    }

    /// The single write path for a text-carrying field.
    private func write(_ field: Field, _ value: String) {
        if field.isSecret || field.kind == .secret {
            // An empty box is "I changed my mind", not "erase my password". Clearing a
            // secret is Delete Field, which is explicit and undoable.
            guard !value.isEmpty else { return }
            model.perform("Save") { library in
                try library.write { db in
                    try library.fields.setSecret(db, fieldID: field.id,
                                                 plaintext: value, dek: library.dek)
                }
            }
            // Re-hide: the value on screen is no longer the one that was revealed.
            revealed[field.id] = nil
            return
        }

        if field.kind == .richText {
            guard value != plainText(of: field) else { return }
            let json: String? = value.isEmpty ? nil : RichTextValue.json(fromPlainText: value)
            model.perform("Save") { library in
                try library.write { db in
                    // Both carriers in one patch: the schema allows at most one to be
                    // non-null, so writing value_json without clearing value_text would be
                    // a CHECK violation on any field that ever held plain text.
                    try library.fields.patchField(db, fieldID: field.id, patch: [
                        "value_json": json.map { JSONValue.string($0) } ?? .null,
                        "value_text": .null
                    ])
                }
            }
            return
        }

        let stored: String? = value.isEmpty ? nil : value
        guard stored != field.valueText else { return }
        writeText(field, stored)
    }

    /// Immediate write for the controls that are their own editor — Toggle, DatePicker,
    /// ColorPicker, the relation picker — and the tail of `write`.
    private func writeText(_ field: Field, _ value: String?) {
        // Belt and braces. `value_text` is cleartext and the schema's second CHECK would
        // reject the row anyway; dropping the write is better than attempting it. Nothing
        // reaches here for a secret today — secrets are neither toggles nor dates — and
        // this is what keeps that true if a kind ever changes.
        guard !field.isSecret, field.kind != .secret else { return }
        model.perform("Save") { library in
            try library.write { db in
                try library.fields.patchField(db, fieldID: field.id, patch: [
                    "value_text": value.map { JSONValue.string($0) } ?? .null,
                    "value_json": .null
                ])
            }
        }
    }

    private func plainText(of field: Field) -> String {
        if field.isSecret || field.kind == .secret {
            return revealed[field.id] ?? ""
        }
        if field.kind == .richText, let json = field.valueJSON {
            return RichTextValue.plainText(fromJSON: json)
        }
        return field.valueText ?? ""
    }

    private func openNoteEditor(_ field: Field) {
        noteDraft = draftFieldID == field.id ? draft : plainText(of: field)
        commitEdit()
        noteEditorField = field
    }

    private func openRelationPicker(_ field: Field) {
        commitEdit()
        relationField = field
    }

    private func commitRename() {
        let name = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != detail?.thing.title else { return }
        model.perform("Rename") { library in
            try library.write { db in
                try library.things.rename(db, id: thingID, title: name)
            }
        }
    }

    /// Fractional reorder: the moved field gets an order between its two new neighbours,
    /// so one row changes rather than every row in the section.
    private func moveFields(_ fields: [Field],
                            sectionID: String?,
                            from source: IndexSet,
                            to destination: Int) {
        guard let sourceIndex = source.first, fields.indices.contains(sourceIndex) else { return }
        let moved = fields[sourceIndex]
        var reordered = fields
        reordered.move(fromOffsets: source, toOffset: destination)
        guard let landing = reordered.firstIndex(where: { $0.id == moved.id }) else { return }
        let after: Field? = landing > 0 ? reordered[landing - 1] : nil
        let before: Field? = landing + 1 < reordered.count ? reordered[landing + 1] : nil
        model.perform("Reorder fields") { library in
            try library.write { db in
                try library.fields.move(db, fieldID: moved.id,
                                        toSection: sectionID, after: after, before: before)
            }
        }
    }

    private func relationTitle(for field: Field) -> String? {
        guard field.kind == .relation,
              let targetID = field.valueText,
              !targetID.isEmpty else { return nil }
        return thingTitles[targetID]
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
        if editingFieldID == field.id { editingFieldID = nil }
        if draftFieldID == field.id {
            draft = ""
            draftFieldID = nil
        }
        model.perform("Delete field") { library in
            try library.write { db in
                try library.fields.deleteField(db, fieldID: field.id)
            }
        }
    }

    private func loadThingTitles() {
        guard let library = model.library else { return }
        let things = (try? library.read { db in try library.things.all(db) }) ?? []
        var titles: [String: String] = [:]
        for thing in things { titles[thing.id] = thing.title }
        thingTitles = titles
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
/// gated all come from the registry. Edit and Open Editor are the exceptions, and they are
/// keyed off the *kind*'s storage rather than off any particular variant.
struct FieldQuickActions: View {

    let field: Field
    let detail: ThingDetail
    let registry: FieldKindRegistry
    let onCopy: (String) -> Void
    let onReveal: () -> Void
    let onEdit: () -> Void
    let onExpand: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let variant = registry.variant(field.variant)
        let actions = variant.map { registry.actions(for: $0) } ?? []

        if isEditable {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
        }

        if isMultiline {
            Button(action: onExpand) {
                Label("Open Editor", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }

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

    private var isEditable: Bool {
        switch field.kind {
        case .text, .longText, .richText, .number, .url, .code, .secret: return true
        default: return false
        }
    }

    private var isMultiline: Bool {
        switch field.kind {
        case .longText, .richText, .code: return true
        default: return false
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
