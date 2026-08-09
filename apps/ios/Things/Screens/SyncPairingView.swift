import SwiftUI
import ThingsCore

/// Sync pairing.
///
/// Pairing is out of band: the computer shows a code, the phone reads it. Being on the same
/// Wi-Fi grants a device nothing — there is no discovery-based auto-trust — and a manual
/// `host:port` path is a first-class route, not a fallback, because mDNS across a Wi-Fi
/// phone and an Ethernet PC is genuinely unreliable.
struct SyncPairingView: View {

    @Environment(AppModel.self) private var model

    @State private var manualHost = ""
    @State private var devices: [Device] = []

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Label("Scan the code on your computer", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                    Text("Open Things on your PC, choose Pair a Device, and point this iPhone at the code it shows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Theme.Spacing.tight)

                Button {
                    // Camera pairing lands with the sync milestone; the screen exists now so
                    // the flow, the wording and the layout are reviewed early.
                    model.errorMessage = "Pairing arrives with sync. The manual address below is the same handshake."
                } label: {
                    Label("Scan Code", systemImage: "camera")
                }
            }

            Section {
                TextField("192.168.1.20:6768", text: $manualHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Connect") {
                    model.errorMessage = "Pairing arrives with sync."
                }
                .disabled(manualHost.isEmpty)
            } header: {
                Text("Or Type the Address")
            } footer: {
                Text("Use this when your phone is on Wi-Fi and your computer is on Ethernet — automatic discovery often cannot see across the two.")
            }

            Section("Paired Devices") {
                if devices.isEmpty {
                    InlineEmptyView(message: "No devices paired yet.")
                } else {
                    ForEach(devices) { device in
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name)
                                    Text(device.isSelf ? "This iPhone" : device.platform.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: device.platform == "ios" ? "iphone" : "desktopcomputer")
                            }
                            Spacer()
                            if device.isSelf {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Sync.root)
        .task { load() }
    }

    private func load() {
        guard let library = model.library else { return }
        devices = (try? library.read { db in
            try library.fileRefs.devices(db)
        }) ?? []
    }
}
