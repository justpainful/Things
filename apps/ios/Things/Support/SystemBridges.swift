import Foundation
import UIKit

/// The two places Things touches the rest of the system.
///
/// Both are deliberately tiny and in one file: an app that claims "zero cloud, no outbound
/// connections ever, except actions you explicitly trigger" should be able to point at
/// every place it leaves its own process.

@MainActor
enum Clipboard {

    /// Secrets are copied with an expiry so a password does not sit in the pasteboard for
    /// the rest of the day. `UIPasteboard` supports this natively.
    static func copy(_ value: String, expiringAfter seconds: TimeInterval? = nil) {
        if let seconds {
            UIPasteboard.general.setItems(
                [[UIPasteboard.typeAutomatic: value]],
                options: [.expirationDate: Date().addingTimeInterval(seconds)]
            )
        } else {
            UIPasteboard.general.string = value
        }
    }

    /// Read **only** when the user taps +. Never in the background: iOS shows a banner on
    /// every clipboard read, and silent monitoring would feel like surveillance even if it
    /// were possible.
    static func suggestion() -> String? {
        guard UIPasteboard.general.hasStrings else { return nil }
        return UIPasteboard.general.string
    }
}

@MainActor
enum Opener {

    /// Explicit, user-triggered, one link at a time. There is no metadata fetch here and no
    /// prefetch — External Metadata ships off.
    static func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme) else { return }
        UIApplication.shared.open(url)
    }
}
