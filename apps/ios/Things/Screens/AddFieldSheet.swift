import SwiftUI
import UIKit
import ThingsCore

/// Add Field.
///
/// Two steps, because they are two decisions. **Pick a type** from the ~50 variants in
/// `spec/field-kinds.json`, grouped and searchable; then **name it and give it a value**,
/// with the keyboard that value actually wants. The previous single-screen version put a
/// details form above a fifty-row list and both were cramped.
///
/// Sizing: one `.large` detent and nothing else. A `.medium` sheet with a keyboard in it
/// spends its life being resized by the keyboard, which is the definition of fighting it.
///
/// No custom background: a custom `presentationBackground` fights the system glass, and the
/// standard sheet material is already correct.
struct AddFieldSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let thingID: String

    @State private var query = ""
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let registry = model.registry {
                    typeList(registry)
                } else {
                    EmptyStateView(symbol: "exclamationmark.triangle",
                                   title: "Field types unavailable",
                                   message: "Things could not read its field registry.")
                }
            }
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(A11y.AddField.cancel)
                }
            }
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search field types")
            .navigationDestination(for: String.self) { variantID in
                destination(for: variantID)
            }
            .accessibilityIdentifier(A11y.Sheets.addField)
        }
        .presentationDetents([.large])
    }

    // MARK: - Step one: the type

    @ViewBuilder
    private func typeList(_ registry: FieldKindRegistry) -> some View {
        let sections = FieldTypeCatalog.sections(in: registry, matching: query)
        if sections.isEmpty {
            EmptyStateView(symbol: "magnifyingglass",
                           title: "No field types match",
                           message: "Try a shorter word — “key”, “file”, “date”.")
        } else {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.variants) { variant in
                            NavigationLink(value: variant.id) {
                                FieldTypeRow(variant: variant)
                            }
                            // Unchanged from the previous sheet, deliberately.
                            .accessibilityIdentifier(A11y.AddField.type(variant.id))
                        }
                    } header: {
                        // On the header rather than the `Section`: a view modifier applied
                        // to a `Section` inside a `List` wraps it in `ModifiedContent`,
                        // which is how a section quietly stops being a section.
                        Text(section.title)
                            .accessibilityIdentifier(A11y.AddField.group(section.id))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier(A11y.AddField.typeList)
        }
    }

    // MARK: - Step two

    @ViewBuilder
    private func destination(for variantID: String) -> some View {
        if let registry = model.registry, let variant = registry.variant(variantID) {
            AddFieldValueStep(thingID: thingID,
                              variant: variant,
                              registry: registry,
                              onFinish: { dismiss() })
        } else {
            EmptyStateView(symbol: "questionmark.square.dashed",
                           title: "Unknown field type",
                           message: "That field type is no longer in the registry.")
        }
    }
}

/// Name the field, give it a value, add it.
///
/// Every branch below writes through `library.write`, so the change lands in the oplog; a
/// secret goes in via `addField(secretPlaintext:dek:)` and is never handed to `valueText`
/// on any path.
struct AddFieldValueStep: View {

    @Environment(AppModel.self) private var model

    let thingID: String
    let variant: FieldKindRegistry.Variant
    let registry: FieldKindRegistry
    let onFinish: () -> Void

    @State private var label = ""
    @State private var text = ""
    @State private var secret = ""
    @State private var flag = false
    @State private var day = Date()
    @State private var colour = Color.blue
    @State private var amount = ""
    @State private var currency = "SAR"
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var relationTarget = ""
    @State private var relationChoices: [Thing] = []
    @State private var localFailure: String?

    @State private var importer = AttachmentImporter()
    @State private var isPresentingPhotos = false
    @State private var isPresentingFiles = false

    @FocusState private var isValueFocused: Bool

    private var isAttachment: Bool { variant.kind == .attachment }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: variant.symbol)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(variant.label).font(.body)
                        Text(FieldTypeCatalog.hint(for: variant))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }

            Section("Name") {
                // An attachment's label is left empty on purpose: empty means "use the
                // file's own name", which is what a person expects to see next to a file.
                TextField("Label",
                          text: $label,
                          prompt: Text(isAttachment ? "The file's name" : variant.label))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.labelField)
            }

            valueSection

            if let message = localFailure {
                Section {
                    AttachmentFailureCard(message: message)
                }
            }
        }
        .navigationTitle(variant.label)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isAttachment {
                    Button("Done") { onFinish() }
                        .disabled(importer.isWorking)
                        .accessibilityIdentifier(A11y.Attach.done)
                } else {
                    Button("Add") { add() }
                        .disabled(!canAdd)
                        .accessibilityIdentifier(A11y.AddField.confirm)
                }
            }
        }
        .attachmentImport(photos: $isPresentingPhotos,
                          files: $isPresentingFiles,
                          thingID: thingID,
                          label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label,
                          maxPhotos: 1,
                          importer: importer)
        .accessibilityIdentifier(A11y.AddField.valueStep)
        .task { await prepare() }
    }

    // MARK: - Value

    @ViewBuilder
    private var valueSection: some View {
        switch variant.kind {

        case .attachment:
            Section("File") {
                AttachmentImportButtons(isPresentingPhotos: $isPresentingPhotos,
                                        isPresentingFiles: $isPresentingFiles,
                                        isEnabled: !importer.isWorking)
                if let progress = importer.progress {
                    AttachmentProgressCard(progress: progress)
                }
                if let summary = importer.summary {
                    AttachmentSummaryCard(summary: summary)
                }
                if let failure = importer.failure {
                    AttachmentFailureCard(message: failure)
                }
            }

        case .secret:
            // `Section(_ title:, content:, footer:)` does not exist in SwiftUI — a Section
            // takes EITHER a string title OR a footer closure, never both. The header has to
            // become a closure too.
            Section {
                SecureField("Value", text: $secret)
                    .textContentType(textContentType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(keyboardType)
                    .focused($isValueFocused)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
            } header: {
                Text("Value")
            } footer: {
                Text("Secrets are encrypted before they are written. Things never stores one in the clear, and it never appears in search.")
            }

        case .boolean:
            Section("Value") {
                Toggle(isOn: $flag) {
                    Text(flag ? "Yes" : "No")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier(A11y.AddField.valueField)
            }

        case .date:
            Section("Value") {
                DatePicker("Value",
                           selection: $day,
                           displayedComponents: variant.id == "datetime" ? [.date, .hourAndMinute] : [.date])
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
            }

        case .color:
            Section("Value") {
                ColorPicker("Colour", selection: $colour, supportsOpacity: false)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
            }

        case .money:
            Section("Value") {
                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                    .focused($isValueFocused)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
                TextField("Currency", text: $currency)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44)
            }

        case .geo:
            Section("Value") {
                TextField("Latitude", text: $latitude)
                    .keyboardType(.numbersAndPunctuation)
                    .focused($isValueFocused)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
                TextField("Longitude", text: $longitude)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(minHeight: 44)
            }

        case .relation:
            Section("Value") {
                if relationChoices.isEmpty {
                    InlineEmptyView(message: "There is nothing else in your library to link to yet.")
                } else {
                    Picker("Thing", selection: $relationTarget) {
                        Text("None").tag("")
                        ForEach(relationChoices) { thing in
                            Text(thing.title).tag(thing.id)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
                }
            }

        case .tagList:
            Section {
                TextField("Tags", text: $text, prompt: Text("work, urgent"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isValueFocused)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
            } header: {
                Text("Tags")
            } footer: {
                Text("Separate tags with commas.")
            }

        case .richText, .longText, .code:
            Section("Value") {
                TextField("Value", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .font(variant.kind == .code ? Font.body.monospaced() : Font.body)
                    .textInputAutocapitalization(capitalization)
                    .autocorrectionDisabled(disablesAutocorrection)
                    .focused($isValueFocused)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
            }

        default:
            Section {
                TextField("Value", text: $text)
                    .keyboardType(keyboardType)
                    .textContentType(textContentType)
                    .textInputAutocapitalization(capitalization)
                    .autocorrectionDisabled(disablesAutocorrection)
                    .focused($isValueFocused)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(A11y.AddField.valueField)
            } header: {
                Text("Value")
            } footer: {
                if let message = validationMessage {
                    Text(message)
                }
            }
        }
    }

    // MARK: - Keyboards

    private var keyboardType: UIKeyboardType {
        switch variant.id {
        case "email": return .emailAddress
        case "phone": return .phonePad
        case "port", "number", "rating", "progress", "pin": return .numberPad
        case "ip": return .numbersAndPunctuation
        default: break
        }
        switch variant.kind.rawValue {
        case "url": return .URL
        case "number", "money": return .decimalPad
        default: return .default
        }
    }

    private var textContentType: UITextContentType? {
        switch variant.id {
        case "email": return .emailAddress
        case "phone": return .telephoneNumber
        case "username": return .username
        case "password": return .password
        case "pin": return .oneTimeCode
        case "address": return .fullStreetAddress
        default: break
        }
        return variant.kind == .url ? .URL : nil
    }

    private var capitalization: TextInputAutocapitalization {
        switch variant.kind.rawValue {
        case "url", "secret", "code", "path": return .never
        default: break
        }
        return ["email", "username", "ip", "reference"].contains(variant.id) ? .never : .sentences
    }

    private var disablesAutocorrection: Bool {
        switch variant.kind.rawValue {
        case "url", "secret", "code", "number", "path": return true
        default: return ["email", "username", "ip", "reference", "port"].contains(variant.id)
        }
    }

    /// The registry's own `validate` regex. Nothing here knows what an email is.
    private var validationMessage: String? {
        guard variant.validate != nil, !trimmedText.isEmpty else { return nil }
        return registry.validate(trimmedText, variantID: variant.id)
            ? nil
            : "That does not look like a valid \(variant.label.lowercased())."
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        guard validationMessage == nil else { return false }
        switch variant.kind {
        case .path:     return !trimmedText.isEmpty
        case .geo:      return Double(latitude) != nil && Double(longitude) != nil
        case .money:    return amount.isEmpty || Double(amount) != nil
        case .relation: return !relationTarget.isEmpty
        default:        return true
        }
    }

    // MARK: - Load and focus

    private func prepare() async {
        if label.isEmpty, !isAttachment { label = variant.label }

        if variant.kind == .relation, let library = model.library {
            let loaded = await Task.detached(priority: .userInitiated) { () async -> [Thing] in
                (try? library.read { db in try library.things.all(db) }) ?? []
            }.value
            relationChoices = loaded.filter { $0.id != thingID }
        }

        guard wantsKeyboard, !model.configuration.isUITesting else { return }
        // A beat, so focus lands after the push settles rather than during it.
        try? await Task.sleep(nanoseconds: 350_000_000)
        isValueFocused = true
    }

    private var wantsKeyboard: Bool {
        switch variant.kind {
        case .attachment, .boolean, .date, .color, .relation: return false
        default: return true
        }
    }

    // MARK: - Write

    private func add() {
        let variantID = variant.id
        let kind = variant.kind
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = trimmedLabel.isEmpty ? variant.label : trimmedLabel
        let entered = trimmedText
        let secretValue = secret
        let isFolder = variantID == "folder"
        let dateValue = Timestamp.string(day)
        let hex = Self.hexString(from: colour)
        let tagNames = entered
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let moneyJSON = JSONValue.object([
            "amount": .string(amount.isEmpty ? "0" : amount),
            "currency": .string(currency.trimmingCharacters(in: .whitespacesAndNewlines))
        ]).canonicalJSON
        let geoJSON = JSONValue.object([
            "lat": .string(latitude),
            "lon": .string(longitude)
        ]).canonicalJSON
        let richTextJSON = JSONValue.object(["text": .string(text)]).canonicalJSON
        let target = relationTarget

        var didWrite = false
        model.perform("Add field") { library in
            try library.write { db in
                switch kind {

                case .secret:
                    // The only path a secret takes. `addField` seals it with the library
                    // key and the row's own id as AAD; `valueText` is never involved.
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                secretPlaintext: secretValue.isEmpty ? nil : secretValue,
                                                dek: library.dek)

                case .path:
                    let reference = try library.fileRefs.create(db,
                                                                deviceID: library.deviceID,
                                                                path: entered,
                                                                isDirectory: isFolder)
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                fileRefID: reference.id)

                case .tagList:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel)
                    for name in tagNames {
                        try library.tags.attach(db, tagName: name, to: thingID)
                    }

                case .boolean:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                valueText: flag ? "1" : "0")

                case .date:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                valueText: dateValue)

                case .color:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                valueText: hex)

                case .money:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                valueJSON: moneyJSON)

                case .geo:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                valueJSON: geoJSON)

                case .richText:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                valueJSON: text.isEmpty ? nil : richTextJSON)

                case .relation:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                valueText: target.isEmpty ? nil : target)

                default:
                    try library.fields.addField(db,
                                                thingID: thingID,
                                                variantID: variantID,
                                                label: finalLabel,
                                                valueText: entered.isEmpty ? nil : entered)
                }
            }
            didWrite = true
        }

        if didWrite {
            onFinish()
        } else {
            // `perform` only ever routes to `AppModel.errorMessage`, which no screen shows.
            // Say it here, on the screen the user is looking at.
            localFailure = model.errorMessage ?? "That field could not be added."
        }
    }

    /// `#RRGGBB` — the only form the `color` kind stores.
    private static func hexString(from color: Color) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#888888"
        }
        return String(format: "#%02X%02X%02X",
                      Int((red * 255).rounded()),
                      Int((green * 255).rounded()),
                      Int((blue * 255).rounded()))
    }
}
