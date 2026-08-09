import SwiftUI
import ThingsCore

/// Settings.
///
/// Deliberately a plain grouped `Form`: "a settings screen that looks like a web form" is
/// on the automatic-rejection list, and the way to avoid that is to use the system's own
/// settings idiom rather than invent one.
struct SettingsView: View {

    @Environment(AppModel.self) private var model
    @State private var openConflicts = 0
    @State private var trashCount = 0
    @State private var isPresentingDiagnostics = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Toggle(isOn: $model.privacyMode) {
                    Label("Privacy Mode", systemImage: "eye.slash")
                }
                .accessibilityIdentifier(A11y.Settings.privacyToggle)
            } footer: {
                Text("Masks secrets, emails and phone numbers on screen. It hides them from the person next to you — it is not a lock.")
            }

            Section("Security") {
                Button {
                    model.lock()
                } label: {
                    Label("Lock Now", systemImage: "lock")
                }
                .accessibilityIdentifier(A11y.Settings.lockNow)

                LabeledContent("Unlock") {
                    Text(DeviceKeyStore.isSecureEnclaveAvailable ? "Face ID and PIN" : "PIN only")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Library") {
                NavigationLink(value: HomeRoute.trash) {
                    HStack {
                        Label("Recently Deleted", systemImage: "trash")
                        Spacer()
                        Text("\(trashCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityIdentifier(A11y.Settings.trash)

                NavigationLink(value: HomeRoute.history(thingID: nil)) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier(A11y.Settings.history)

                NavigationLink(value: HomeRoute.conflicts) {
                    HStack {
                        Label("Conflicts", systemImage: "arrow.triangle.branch")
                        Spacer()
                        if openConflicts > 0 {
                            Text("\(openConflicts)").foregroundStyle(.orange).monospacedDigit()
                        }
                    }
                }
                .accessibilityIdentifier(A11y.Settings.conflicts)
            }

            Section {
                NavigationLink(value: HomeRoute.sync) {
                    Label("Sync with a Computer", systemImage: "laptopcomputer.and.iphone")
                }
                .accessibilityIdentifier(A11y.Settings.sync)
            } footer: {
                Text("Things syncs directly with your own computer over your local network. Nothing is sent to the internet, and there is no account.")
            }

            Section("About") {
                LabeledContent("Version", value: ThingsCoreInfo.version)
                LabeledContent("Device", value: DeviceInfo.name)
                Button {
                    isPresentingDiagnostics = true
                } label: {
                    Label("Storage Diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier(A11y.Settings.diagnostics)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Settings.root)
        .sheet(isPresented: $isPresentingDiagnostics) {
            DiagnosticsSheet(diagnostics: model.diagnostics)
        }
        .task { load() }
    }

    private func load() {
        guard let library = model.library else { return }
        let counts = try? library.read { db -> (Int, Int) in
            (try library.things.trashed(db).count,
             try library.conflicts.openConflicts(db).count)
        }
        trashCount = counts?.0 ?? 0
        openConflicts = counts?.1 ?? 0
    }
}

/// The FTS5 answer, in the UI as well as the log.
///
/// It is genuinely unverified whether FTS5 is compiled into the SQLCipher binary this app
/// links. Rather than discover it as a mysterious empty search, the app measures it at
/// startup and says so here.
struct DiagnosticsSheet: View {

    @Environment(\.dismiss) private var dismiss
    let diagnostics: SQLiteDiagnostics?

    var body: some View {
        NavigationStack {
            Form {
                if let diagnostics {
                    Section("Storage") {
                        LabeledContent("SQLite", value: diagnostics.sqliteVersion)
                        LabeledContent("SQLCipher", value: diagnostics.cipherVersion ?? "Not detected")
                        LabeledContent("Encrypted", value: diagnostics.isEncrypted ? "Yes" : "No")
                    }
                    Section {
                        LabeledContent("Full-text search",
                                       value: diagnostics.hasFTS5 ? "FTS5" : "Fallback (LIKE)")
                    } footer: {
                        Text(diagnostics.hasFTS5
                             ? "Search uses SQLite's full-text index."
                             : "This build of SQLCipher has no FTS5 module, so search falls back to a slower scan. Everything still works.")
                    }
                    Section("Compile Options") {
                        ForEach(diagnostics.compileOptions.prefix(40), id: \.self) { option in
                            Text(option).font(.caption.monospaced())
                        }
                    }
                } else {
                    Text("No library is open.")
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
