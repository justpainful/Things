import SwiftUI

/// The full-height editor for a Note, a Long Text or a block of Code.
///
/// The inline field on the detail screen grows to about fourteen lines, which covers a
/// paragraph comfortably. Past that the row is taller than the screen and scrolling the
/// list to read what you are typing stops being editing. This is where anything longer
/// goes — and it is the only place in the app with a `TextEditor`.
///
/// No `presentationBackground`, no `scrollContentBackground(.hidden)`: a custom sheet
/// background fights the system glass, and clearing the editor's own background would put
/// the sheet material *behind text you are typing*, which is the one thing the design
/// system forbids outright.
struct NoteEditorSheet: View {

    @Environment(\.dismiss) private var dismiss

    let title: String
    let isMonospaced: Bool
    let onSave: (String) -> Void

    /// A copy, not a binding. Cancel has to mean cancel, and a binding straight back into
    /// the detail screen's draft would have already overwritten it by then.
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(title: String,
         initialText: String,
         isMonospaced: Bool,
         onSave: @escaping (String) -> Void) {
        self.title = title
        self.isMonospaced = isMonospaced
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(isMonospaced ? Font.callout.monospaced() : Font.body)
                .focused($isFocused)
                .padding(.horizontal, Theme.Spacing.small)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onSave(text)
                            dismiss()
                        }
                    }
                }
                .accessibilityIdentifier(A11y.Sheets.noteEditor)
        }
        .task {
            // One run-loop hop before taking focus: a text view that has only just been
            // inserted is not yet known to the focus system, and the request is dropped.
            try? await Task.sleep(nanoseconds: 50_000_000)
            isFocused = true
        }
    }
}
