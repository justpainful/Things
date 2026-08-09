import SwiftUI
import ThingsCore

/// New Thing — blank, or from one of the seeded templates.
///
/// A Template is just a Thing with `is_template = 1`, so "Save as Template" needs no second
/// editor and no second schema. The list here comes from the registry.
struct NewThingSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var selectedTemplate: String = "blank"
    @State private var clipboardSuggestion: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("newThing.title")
                }

                if let clipboardSuggestion {
                    Section {
                        Button {
                            title = clipboardSuggestion
                            self.clipboardSuggestion = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use what you copied").font(.subheadline)
                                Text(clipboardSuggestion)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } footer: {
                        // Read once, on tap, never in the background.
                        Text("Things only looks at the clipboard when you open this screen.")
                    }
                }

                Section("Start From") {
                    ForEach(model.registry?.templates ?? []) { template in
                        Button {
                            selectedTemplate = template.id
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(template.name)
                                        if template.fieldCount > 0 {
                                            Text("\(template.fieldCount) fields")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: template.symbol)
                                }
                                Spacer()
                                if selectedTemplate == template.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("newThing.template.\(template.id)")
                    }
                }
            }
            .navigationTitle("New Thing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .accessibilityIdentifier(A11y.Sheets.newThing)
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            guard !model.configuration.isUITesting else { return }
            clipboardSuggestion = Clipboard.suggestion()
        }
    }

    private func create() {
        let finalTitle = title.trimmingCharacters(in: .whitespaces)
        let templateID = selectedTemplate
        model.perform("Create") { library in
            try library.write { db in
                if templateID == "blank" || library.registry.template(templateID) == nil {
                    _ = try library.things.create(db, title: finalTitle)
                } else if let template = library.registry.template(templateID) {
                    _ = try library.things.createFromTemplate(db, template: template, title: finalTitle)
                }
            }
        }
        dismiss()
    }
}
