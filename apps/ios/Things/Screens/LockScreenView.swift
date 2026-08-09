import SwiftUI
import ThingsCore

/// The lock screen — **Face ID only**.
///
/// There is no PIN in Things and no keypad. A six-digit pad in front of a personal library is
/// a second passcode to invent, remember, and eventually forget, on top of the one the phone
/// already has. The device keychain is the lock; Face ID is an optional extra gate on top of
/// it, off by default.
///
/// This screen therefore appears **only** when the user has switched Face ID on in Settings.
/// With it off, Things opens straight into the library like any other app.
struct LockScreenView: View {

    enum Mode {
        case unlock
        /// Retained so the app has somewhere to land if a library ever exists without a
        /// wrapper. It is unreachable in the normal flow: first run creates and opens the
        /// library without asking for anything.
        case create
    }

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    let mode: Mode

    @State private var didAttempt = false

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Spacer()

            Image(systemName: "faceid")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.tight) {
                Text("Things is locked")
                    .font(.title2.weight(.semibold))
                Text("Unlock with Face ID to open your library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let message = model.unlockMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.destructive)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.large)
            }

            Spacer()

            Button {
                unlock()
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .font(.headline)
                    // 44pt is Apple's minimum touch target and this is the only control on
                    // the screen; it should be impossible to miss.
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier(A11y.Lock.faceID)
            .padding(.horizontal, Theme.Spacing.large)

            Spacer().frame(height: Theme.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11y.Lock.root)
        // Prompt once on appear rather than making the user tap a button to be asked for a
        // face they were about to present anyway.
        .task {
            guard !didAttempt, !model.configuration.isUITesting else { return }
            didAttempt = true
            unlock()
        }
        // Coming back from the background re-arms the prompt, so a dismissed Face ID sheet
        // does not strand the user on a screen whose only button they already pressed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { didAttempt = false }
        }
    }

    private func unlock() {
        model.unlockWithDevice()
    }
}
