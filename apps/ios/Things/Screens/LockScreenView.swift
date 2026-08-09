import SwiftUI
import ThingsCore

/// PIN entry, and first-run PIN creation.
///
/// A six-digit PIN is a million possibilities, which is why it is never the whole story:
/// the key is bound to this device as well, so copying the folder yields nothing. The PIN
/// path is also the *recovery* route — biometrics are convenience on top, never the sole
/// door, because `.biometryCurrentSet` permanently invalidates the device key the moment
/// Face ID is re-enrolled.
struct LockScreenView: View {

    enum Mode {
        case unlock
        case create
    }

    @Environment(AppModel.self) private var model

    let mode: Mode

    @State private var entered = ""
    @State private var confirming = false
    @State private var firstEntry = ""
    @State private var keypadTaps = 0

    private let digitsRequired = 6

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Spacer(minLength: 0)

            VStack(spacing: Theme.Spacing.small) {
                Image(systemName: mode == .create ? "lock.badge.clock" : "lock.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.large)
            }

            dots

            if let message = model.unlockMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.large)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keypad

            if mode == .unlock {
                Button {
                    model.unlockWithDevice()
                } label: {
                    Label("Use Face ID", systemImage: "faceid")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .thingsConcentricGlass()
                .accessibilityIdentifier(A11y.Lock.faceID)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.selection, trigger: keypadTaps)
        .accessibilityIdentifier(A11y.Lock.root)
    }

    private var title: String {
        switch mode {
        case .create: return confirming ? "Confirm your PIN" : "Choose a PIN"
        case .unlock: return "Things is locked"
        }
    }

    private var subtitle: String {
        switch mode {
        case .create:
            return "Six digits. Your PIN never leaves this iPhone, and Things can never recover it for you — so pick one you will remember."
        case .unlock:
            return "Enter your PIN, or use Face ID."
        }
    }

    private var dots: some View {
        HStack(spacing: Theme.Spacing.medium) {
            ForEach(0..<digitsRequired, id: \.self) { index in
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                    .background {
                        Circle().fill(index < entered.count ? Color.accentColor : Color.clear)
                    }
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entered.count) of \(digitsRequired) digits entered")
    }

    private var keypad: some View {
        // One GlassEffectContainer around the whole keypad: Apple is explicit that many
        // separate containers, or effects applied outside one, cost performance.
        GlassEffectContainer {
            VStack(spacing: Theme.Spacing.small) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: Theme.Spacing.small) {
                        ForEach(0..<3, id: \.self) { column in
                            keyView(row: row, column: column)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(A11y.Lock.keypad)
    }

    @ViewBuilder
    private func keyView(row: Int, column: Int) -> some View {
        let index = row * 3 + column
        if row < 3 {
            digitButton(index + 1)
        } else if column == 0 {
            Color.clear.frame(width: 72, height: 58)
        } else if column == 1 {
            digitButton(0)
        } else {
            Button {
                keypadTaps += 1
                if !entered.isEmpty { entered.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.title3)
                    .frame(width: 72, height: 58)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
        }
    }

    private func digitButton(_ value: Int) -> some View {
        Button {
            keypadTaps += 1
            append(value)
        } label: {
            Text("\(value)")
                .font(.title2)
                .monospacedDigit()
                .frame(width: 72, height: 58)
        }
        .buttonStyle(.plain)
        .thingsInteractiveGlass(cornerRadius: Theme.Radius.chip)
        .accessibilityIdentifier(A11y.Lock.digit(value))
    }

    private func append(_ value: Int) {
        guard entered.count < digitsRequired else { return }
        entered.append(String(value))
        guard entered.count == digitsRequired else { return }

        switch mode {
        case .unlock:
            let pin = entered
            entered = ""
            model.unlock(pin: pin)
        case .create:
            if confirming {
                if entered == firstEntry {
                    let pin = entered
                    entered = ""
                    model.createLibrary(pin: pin)
                } else {
                    model.unlockMessage = "Those did not match. Start again."
                    confirming = false
                    firstEntry = ""
                    entered = ""
                }
            } else {
                firstEntry = entered
                entered = ""
                confirming = true
                model.unlockMessage = nil
            }
        }
    }
}
