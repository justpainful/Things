import SwiftUI
import UIKit
import ThingsCore

/// One field cell in a Thing's detail — **and its editor**.
///
/// This is content, so there is no glass here. The glass in this screen belongs to the
/// navigation bar and the floating actions above it.
///
/// Two shapes of editing live here, and the split is deliberate:
///
///  * Kinds whose control *is* their display — `boolean`, `date`, `color`, `relation` —
///    are always live. A switch, a date well and a colour well already read as editable,
///    so hiding them behind a tap state would only add a step.
///  * Kinds carrying text — `text`, `number`, `url`, `longText`, `richText`, `code`,
///    `secret` — render as text until tapped, then swap in a field. That keeps the row
///    selectable and long-pressable (the context menu is how Copy and Reveal are reached),
///    keeps a 20 000-word note from living inside a text view it does not need to, and
///    keeps the read-only screenshots readable.
///
/// The draft string and "which field is being edited" both belong to the detail screen,
/// not to the row: only one field can be edited at a time, and hoisting the state means a
/// list refresh mid-edit cannot silently discard what was typed.
struct FieldRowView: View {

    let field: Field
    let detail: ThingDetail
    let registry: FieldKindRegistry
    let privacyMode: Bool
    var revealedValue: String?
    var onReveal: (() -> Void)?
    var onCopy: ((String) -> Void)?

    // MARK: Editing

    /// Title of a `relation` target, resolved by the detail screen — the target of a
    /// forward relation is not in `detail`, only the things pointing back at this one are.
    var relationTitle: String?
    /// The present, injected. A date field with no value has to be filled with *something*
    /// when the user taps it, and `Date()` would make the Screenshot Tour drift.
    var nowMilliseconds: Int64 = 0
    var isEditing: Bool = false
    @Binding var draft: String
    var onBeginEditing: (() -> Void)?
    /// Commits the draft. Carries the field id so a row that is being torn down can never
    /// commit over the field that replaced it.
    var onCommit: ((String) -> Void)?
    /// Immediate write, for the controls that are their own editor. `nil` clears the value.
    var onWriteText: ((String?) -> Void)?
    var onPickRelation: (() -> Void)?
    var onExpandEditor: (() -> Void)?

    @FocusState private var isFocused: Bool

    private var variant: FieldKindRegistry.Variant? {
        registry.variant(field.variant)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: variant?.symbol ?? "textformat")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                valueArea
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole label-and-value column is the tap target, not just the glyphs of
            // the value. An empty field is the case that matters most, and its value is
            // one short line of placeholder text.
            .contentShape(Rectangle())
            .onTapGesture {
                guard isTextEditable, !isEditing else { return }
                onBeginEditing?()
            }

            trailingAccessory
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: 44)
        .accessibilityIdentifier(A11y.Detail.field(field.id))
        // A combined element is right for a row that is only text. The moment the row owns
        // a switch, a picker or a text field, combining hides that control from VoiceOver
        // and from the tour.
        .accessibilityElement(children: hostsControl ? .contain : .combine)
    }

    // MARK: - Kind groups

    /// Kinds that swap a text field in when tapped.
    private var isTextEditable: Bool {
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

    /// Kinds whose control is always on screen.
    private var isLiveControl: Bool {
        switch field.kind {
        case .boolean, .date, .color, .relation: return true
        default: return false
        }
    }

    private var hostsControl: Bool { isEditing || isLiveControl }

    // MARK: - Value

    @ViewBuilder
    private var valueArea: some View {
        switch field.kind {
        case .boolean:
            Text(field.valueText == "1" ? "Yes" : "No")
                .font(.body)

        case .date:
            dateArea

        case .color:
            colorArea

        case .relation:
            relationArea

        default:
            if isEditing {
                editorArea
            } else {
                readOnlyArea
            }
        }
    }

    @ViewBuilder
    private var readOnlyArea: some View {
        if isTextEditable && !field.hasValue {
            // The complaint this whole screen exists to answer: a field you added and
            // cannot put anything in. An empty field now says how to fill it.
            Text("Tap to add")
                .font(.body)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        } else {
            staticValue
        }
    }

    @ViewBuilder
    private var staticValue: some View {
        switch field.kind {
        case .code:
            Text(displayText)
                .font(.callout.monospaced())
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)

        case .attachment:
            attachmentView

        case .path:
            pathView

        case .richText, .longText:
            Text(displayText)
                .font(.body)
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)

        default:
            Text(displayText)
                .font(.body)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Editors

    @ViewBuilder
    private var editorArea: some View {
        Group {
            switch field.kind {
            case .secret:
                secretEditor
            case .longText, .richText, .code:
                multilineEditor
            default:
                singleLineEditor
            }
        }
        .task { await focusShortly() }
        // Commit on blur, whichever way the keyboard went away — Done, the return key, an
        // interactive scroll dismiss, or a tap on another field. `isEditing` is the detail
        // screen's state, so a row that has already been replaced does nothing here.
        .onChange(of: isFocused) { _, focused in
            if !focused && isEditing { onCommit?(field.id) }
        }
    }

    private var singleLineEditor: some View {
        TextField(field.label, text: $draft)
            .font(.body)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(disablesAutocorrection)
            .submitLabel(.done)
            .onSubmit { onCommit?(field.id) }
            .frame(minHeight: 44)
            .accessibilityIdentifier(A11y.Detail.fieldEditor(field.id))
    }

    /// Grows with what is typed rather than scrolling inside one line. For anything longer
    /// than a screenful there is the Expand button, which opens the full-height editor.
    private var multilineEditor: some View {
        TextField(field.label, text: $draft, axis: .vertical)
            .font(field.kind == .code ? Font.callout.monospaced() : Font.body)
            .textFieldStyle(.plain)
            .lineLimit(4...14)
            .focused($isFocused)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(disablesAutocorrection)
            .frame(minHeight: 88, alignment: .topLeading)
            .accessibilityIdentifier(A11y.Detail.fieldEditor(field.id))
    }

    /// A secret is typed masked unless it is already revealed. Either way the string never
    /// reaches `value_text` — the detail screen writes it through `setSecret`, which seals
    /// it against the library key before anything touches the row.
    @ViewBuilder
    private var secretEditor: some View {
        if revealedValue == nil {
            SecureField("New value", text: $draft)
                .font(.body)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { onCommit?(field.id) }
                .frame(minHeight: 44)
                .accessibilityIdentifier(A11y.Detail.fieldEditor(field.id))
        } else {
            TextField("New value", text: $draft)
                .font(.body)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { onCommit?(field.id) }
                .frame(minHeight: 44)
                .accessibilityIdentifier(A11y.Detail.fieldEditor(field.id))
        }
    }

    /// One run-loop hop before taking focus. A field that has only just been inserted into
    /// the hierarchy is not yet known to the focus system, and asking in the same update
    /// drops the request silently — leaving a field that looks editable and is not.
    private func focusShortly() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
        isFocused = true
    }

    // MARK: - Live controls

    @ViewBuilder
    private var dateArea: some View {
        if field.valueText == nil || field.valueText?.isEmpty == true {
            Text("Tap to add")
                .font(.body)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onWriteText?(Timestamp.string(millisecondsSinceEpoch: nowMilliseconds))
                }
                .accessibilityIdentifier(A11y.Detail.fieldEditor(field.id))
        } else {
            DatePicker("", selection: dateBinding, displayedComponents: dateComponents)
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(minHeight: 44)
                .accessibilityLabel(field.label)
                .accessibilityIdentifier(A11y.Detail.fieldEditor(field.id))
        }
    }

    private var dateComponents: DatePickerComponents {
        variantID == "datetime" ? [.date, .hourAndMinute] : [.date]
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                guard let text = field.valueText, let date = Timestamp.date(fromISO8601: text) else {
                    return Timestamp.date(millisecondsSinceEpoch: nowMilliseconds)
                }
                return date
            },
            set: { newValue in
                let text = Timestamp.string(newValue)
                if text != field.valueText { onWriteText?(text) }
            }
        )
    }

    private var colorArea: some View {
        ColorPicker(selection: colorBinding, supportsOpacity: false) {
            Text(field.valueText ?? "Tap to add")
                .font(.body.monospaced())
                .lineLimit(1)
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier(A11y.Detail.fieldEditor(field.id))
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: field.valueText ?? "#888888") },
            set: { newValue in
                let hex = HexColor.string(from: newValue)
                if hex != field.valueText { onWriteText?(hex) }
            }
        )
    }

    private var relationArea: some View {
        Button {
            onPickRelation?()
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Label(relationDisplayTitle, systemImage: "link")
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier(A11y.Detail.fieldEditor(field.id))
    }

    private var relationDisplayTitle: String {
        if let relationTitle, !relationTitle.isEmpty { return relationTitle }
        if let targetID = field.valueText,
           let target = detail.backlinks.first(where: { $0.id == targetID }) {
            return target.title
        }
        if let targetID = field.valueText, !targetID.isEmpty { return "Related Thing" }
        return "Choose a Thing"
    }

    // MARK: - Trailing accessories

    @ViewBuilder
    private var trailingAccessory: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if field.isSecret {
                accessoryButton(symbol: revealedValue == nil ? "eye" : "eye.slash",
                                label: revealedValue == nil ? "Reveal" : "Hide",
                                identifier: A11y.Detail.fieldReveal(field.id)) {
                    onReveal?()
                }
            }
            if isEditing && isMultiline {
                accessoryButton(symbol: "arrow.up.left.and.arrow.down.right",
                                label: "Expand",
                                identifier: A11y.Detail.fieldExpand(field.id)) {
                    onExpandEditor?()
                }
            }
            if isEditing {
                Button {
                    onCommit?(field.id)
                } label: {
                    Text("Done").font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier(A11y.Detail.fieldDone(field.id))
            }
            if field.kind == .boolean {
                Toggle("", isOn: booleanBinding)
                    .labelsHidden()
                    .frame(minHeight: 44)
                    .accessibilityLabel(field.label)
                    .accessibilityIdentifier(A11y.Detail.fieldToggle(field.id))
            }
        }
    }

    /// A 22pt glyph in a 44pt target. The glyph is what you see; the square is what you hit.
    private func accessoryButton(symbol: String,
                                 label: String,
                                 identifier: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var booleanBinding: Binding<Bool> {
        Binding(
            get: { field.valueText == "1" },
            set: { onWriteText?($0 ? "1" : "0") }
        )
    }

    // MARK: - Keyboards

    /// The variant id, never optional — a `switch` subject that is `String?` needs every
    /// pattern spelled as an optional, and that is a footgun in a file nobody can compile
    /// before it ships.
    private var variantID: String { variant?.id ?? "" }

    private var keyboardType: UIKeyboardType {
        switch variantID {
        case "email": return .emailAddress
        case "phone": return .phonePad
        case "port": return .numberPad
        default: break
        }
        switch field.kind {
        case .url: return .URL
        case .number: return .decimalPad
        default: return .default
        }
    }

    private var autocapitalization: TextInputAutocapitalization {
        switch variantID {
        case "email", "username", "ip", "reference": return .never
        default: break
        }
        switch field.kind {
        case .url, .number, .code, .secret: return .never
        default: return .sentences
        }
    }

    private var disablesAutocorrection: Bool {
        switch variantID {
        case "email", "username", "ip", "reference": return true
        default: break
        }
        switch field.kind {
        case .url, .number, .code, .secret: return true
        default: return false
        }
    }

    // MARK: - Attachments and paths

    @ViewBuilder
    private var attachmentView: some View {
        if let hash = field.objectHash, let object = detail.objects[hash] {
            VStack(alignment: .leading, spacing: 1) {
                Text(field.filename ?? "Attached file").font(.body).lineLimit(1)
                Text("\(object.mimeType ?? "File") · \(ByteSize.string(object.byteSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let refID = field.fileRefID, let ref = detail.fileRefs[refID] {
            fileReferenceView(ref)
        } else {
            Text("Not on this iPhone")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pathView: some View {
        if let refID = field.fileRefID, let ref = detail.fileRefs[refID] {
            fileReferenceView(ref)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func fileReferenceView(_ ref: FileRef) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ref.path)
                .font(.callout.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: Theme.Spacing.tight) {
                if ref.statusValue == .missing {
                    Label("Missing", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(deviceName(ref.deviceID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deviceName(_ deviceID: String) -> String {
        // The seed and the real library both keep the self device row, so the common case
        // resolves; anything else shows the raw id rather than pretending.
        deviceID
    }

    // MARK: - Text

    private var displayText: String {
        if field.isSecret {
            if let revealedValue { return revealedValue }
            return String(repeating: "•", count: 12)
        }
        if privacyMode && isPrivate {
            return String(repeating: "•", count: 10)
        }
        if let text = field.valueText, !text.isEmpty { return text }
        if let json = field.valueJSON {
            switch field.kind {
            case .money:
                let parsed = try? JSONValue.parse(json)
                let amount = parsed?["amount"]?.stringValue ?? "0"
                let currency = parsed?["currency"]?.stringValue ?? ""
                return "\(amount) \(currency)".trimmingCharacters(in: .whitespaces)
            case .geo:
                let parsed = try? JSONValue.parse(json)
                let latitude: String = FieldRowView.scalar(parsed, "lat")
                let longitude: String = FieldRowView.scalar(parsed, "lon")
                return "\(latitude), \(longitude)"
            case .richText:
                return RichTextValue.plainText(fromJSON: json)
            default:
                return json
            }
        }
        return "—"
    }

    /// Pulls a scalar out of a parsed JSON value as text, whether it was written as a
    /// string or a number.
    private static func scalar(_ value: JSONValue?, _ key: String) -> String {
        guard let member = value?[key] else { return "0" }
        if let text = member.stringValue { return text }
        if case .number(let text) = member { return text }
        return "0"
    }

    /// Privacy Mode masks secrets, emails, phones and keys. It is a display state, not a
    /// security boundary, and the UI does not imply otherwise.
    private var isPrivate: Bool {
        if field.isSecret { return true }
        guard let variant else { return false }
        return ["email", "phone", "username", "ip", "reference"].contains(variant.id)
    }
}

/// The `richText` payload, read and written in one place.
///
/// `spec/richtext.md` is deferred to M4, so the tree format is not settled. Until it is,
/// the editor writes the smallest thing that both cores and the search indexer already
/// understand — a single `text` member — and reads anything by falling back to the same
/// generic walk the indexer uses.
enum RichTextValue {

    static func plainText(fromJSON json: String) -> String {
        if let parsed = try? JSONValue.parse(json), let text = parsed["text"]?.stringValue {
            return text
        }
        return SearchIndexer.plainText(fromRichTextJSON: json)
    }

    static func json(fromPlainText text: String) -> String {
        JSONValue.object(["text": .string(text)]).canonicalJSON
    }
}

enum HexColor {

    /// `#RRGGBB` — the only form the `color` kind stores.
    static func string(from color: Color) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#888888"
        }
        // Built by hand rather than with `String(format:)`: `%02X` is a C varargs contract
        // written for a 32-bit unsigned int, and this file has no way to be compiled and
        // checked before it ships.
        func channel(_ value: CGFloat) -> String {
            let byte = Int((min(max(value, 0), 1) * 255).rounded())
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }
        return "#" + channel(red) + channel(green) + channel(blue)
    }
}

extension Color {

    /// `#RRGGBB`, the only form the `color` kind stores.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
