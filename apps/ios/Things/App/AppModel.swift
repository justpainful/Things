import Foundation
import SwiftUI
import Observation
import CryptoKit
import ThingsCore

/// The app's single piece of long-lived state: which library is open, whether it is
/// unlocked, and whether Privacy Mode is on.
///
/// Everything else is derived per screen from a live query.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        /// Working out what kind of launch this is.
        case launching
        /// No library yet — the user chooses a PIN.
        case setup
        /// A library exists and is closed.
        case locked
        case unlocked
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    private(set) var library: Library?
    private(set) var registry: FieldKindRegistry?

    /// A display state, not a security boundary — and the UI must not imply otherwise.
    /// Masks every secret, email, phone and key on screen without locking the app.
    var privacyMode = false

    /// Shown under the keypad. Never says which digit was wrong, obviously.
    var unlockMessage: String?
    var failedAttempts = 0

    /// Transient banner for a failed action.
    var errorMessage: String?

    /// The present, frozen for the duration of a Screenshot Tour pass.
    private(set) var displayNowMilliseconds: Int64 = 0

    private(set) var diagnostics: SQLiteDiagnostics?

    let configuration = LaunchConfiguration.current
    private var clock: ThingsClock = SystemClock.shared
    private var vault: Vault?
    private var locations: Library.Locations?

    var isUnlocked: Bool { phase == .unlocked && library != nil }

    // MARK: - Bootstrap

    func bootstrapIfNeeded() {
        guard phase == .launching else { return }
        privacyMode = configuration.privacyMode
        do {
            registry = try FieldKindRegistry.loadBundled()
        } catch {
            phase = .failed("Things could not read its field registry. \(error)")
            return
        }
        if configuration.isUITesting {
            bootstrapForUITesting()
        } else {
            bootstrapNormally()
        }
    }

    private func bootstrapNormally() {
        displayNowMilliseconds = Timestamp.milliseconds(Date())
        do {
            let locations = try Library.Locations.standard()
            self.locations = locations
            let vault = Vault(storage: FileVaultStorage(url: locations.vaultURL), clock: SystemClock.shared)
            self.vault = vault

            // No PIN. Ever.
            //
            // On first run the library creates itself and opens — there is no passcode to
            // invent and no setup screen to get through. The DEK is protected by this
            // device's keychain, which is the phone's own passcode, and optionally Face ID
            // if the user turns it on in Settings. That is how a normal iOS app behaves.
            //
            // The trade is stated plainly in Vault.initialiseDeviceOnly: with no passphrase
            // there is no second way in, so encrypted backup is the recovery path.
            if try vault.state().isInitialised {
                if vault.requiresBiometrics {
                    phase = .locked
                } else {
                    let dek = try vault.unlockWithDevice()
                    try openLibrary(dek: dek, locations: locations)
                }
            } else {
                let dek = try vault.initialiseDeviceOnly()
                try openLibrary(dek: dek, locations: locations)
            }
        } catch {
            phase = .failed("Things could not open its storage. \(error)")
        }
    }

    /// A throwaway library in the temporary directory, wiped and rebuilt on every launch,
    /// filled with the fictional seed dataset. There is no code path from a real library to
    /// a CI artifact, and `SeedData` writes a marker row that the tour asserts before it
    /// takes a single screenshot.
    private func bootstrapForUITesting() {
        let fixed = FixedClock(startISO8601: LaunchConfiguration.seedNowISO8601, stepMilliseconds: 1)
        clock = fixed
        displayNowMilliseconds = Timestamp.milliseconds(fromISO8601: LaunchConfiguration.seedNowISO8601) ?? 0

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ThingsUITest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)

        do {
            let locations = Library.Locations(root: root)
            self.locations = locations
            let library = try Library.open(
                locations: locations,
                dek: SeedData.uiTestingKey,
                deviceID: SeedData.deviceID,
                deviceName: "Screenshot Tour iPhone",
                clock: fixed
            )
            try library.installSmartViewsIfNeeded()
            try SeedData.populate(library, clock: fixed)
            adopt(library)
            phase = configuration.startsLocked ? .locked : .unlocked
        } catch {
            phase = .failed("Seed data failed: \(error)")
        }
    }

    private func adopt(_ library: Library) {
        self.library = library
        self.diagnostics = library.diagnostics
        // Printed once per launch. This is the answer to the one genuinely unverified
        // question in the persistence stack: is FTS5 in the linked SQLCipher binary?
        print(library.diagnostics.logLine)
    }

    // MARK: - Unlock

    func createLibrary(pin: String) {
        guard let vault, let locations else { return }
        do {
            let dek = try vault.initialise(pin: pin)
            try openLibrary(dek: dek, locations: locations)
            if let opened = library {
                try vault.mirrorIntoDatabase(opened.database)
            }
        } catch {
            phase = .failed("Things could not create your library. \(error)")
        }
    }

    func unlock(pin: String) {
        unlockMessage = nil

        if configuration.isUITesting {
            // The tour needs the lock screen photographed and then dismissed. There is no
            // PIN material in the seed at all, so any six digits open it.
            if pin.count == 6 {
                phase = .unlocked
            } else {
                unlockMessage = "Enter your six-digit PIN."
            }
            return
        }

        guard let vault, let locations else { return }
        do {
            let dek = try vault.unlockWithPIN(pin)
            failedAttempts = 0
            try openLibrary(dek: dek, locations: locations)
        } catch {
            failedAttempts += 1
            let wait = KeyHierarchy.lockoutSeconds(afterFailedAttempts: failedAttempts)
            unlockMessage = wait > 0
                ? "That PIN did not work. Try again in \(wait) second\(wait == 1 ? "" : "s")."
                : "That PIN did not work."
        }
    }

    /// Whether opening Things demands Face ID. Off by default.
    var requiresBiometrics: Bool { vault?.requiresBiometrics ?? false }

    /// Turning this on or off re-wraps the key under a new keychain policy — an access
    /// control cannot be edited in place. It is done inside `Vault` in an order where a
    /// failure leaves the old, working wrapper on disk.
    func setBiometricRequirement(_ required: Bool) {
        guard let vault, !configuration.isUITesting else { return }
        do {
            try vault.setBiometricRequirement(required)
        } catch {
            errorMessage = required
                ? "Face ID could not be turned on. \(error.localizedDescription)"
                : "Face ID could not be turned off. \(error.localizedDescription)"
        }
    }

    func unlockWithDevice() {
        if configuration.isUITesting {
            phase = .unlocked
            return
        }
        guard let vault, let locations else { return }
        do {
            let dek = try vault.unlockWithDevice()
            failedAttempts = 0
            try openLibrary(dek: dek, locations: locations)
        } catch {
            unlockMessage = "Face ID could not open Things. \(error.localizedDescription)"
        }
    }

    private func openLibrary(dek: SymmetricKey, locations: Library.Locations) throws {
        let library = try Library.open(
            locations: locations,
            dek: dek,
            deviceID: try deviceIdentifier(),
            deviceName: DeviceInfo.name,
            clock: clock
        )
        try library.installSmartViewsIfNeeded()
        try library.runMaintenance()
        adopt(library)
        phase = .unlocked
    }

    func lock() {
        if configuration.isUITesting {
            // Keep the seeded library in memory; re-seeding mid-tour would change every id.
            phase = .locked
            return
        }
        library?.close()
        library = nil
        phase = .locked
    }

    /// A device id that survives reinstalls of the same bundle id, stored beside the vault
    /// rather than in the keychain — the keychain is the thing most likely to disappear.
    private func deviceIdentifier() throws -> String {
        guard let vault else { return UUIDv7.generate(clock: clock) }
        if let existing = try vault.storage.value(forKey: MetaKey.deviceID) { return existing }
        let created = UUIDv7.generate(clock: clock)
        try vault.storage.setValue(created, forKey: MetaKey.deviceID)
        return created
    }

    // MARK: - Convenience for views

    func perform(_ action: String = "", _ work: (Library) throws -> Void) {
        guard let library else { return }
        do {
            try work(library)
        } catch {
            errorMessage = action.isEmpty ? "\(error)" : "\(action) failed. \(error)"
        }
    }

    /// Reveal a secret. In production this is where a second Face ID gate would sit; the
    /// gate is a setting, and the PIN path never depends on it.
    func revealSecret(fieldID: String) -> String? {
        guard let library else { return nil }
        return try? library.write { db in
            try library.fields.revealSecret(db, fieldID: fieldID, dek: library.dek)
        }
    }
}

enum DeviceInfo {
    static var name: String {
        #if targetEnvironment(simulator)
        return "iPhone Simulator"
        #else
        return "iPhone"
        #endif
    }
}
