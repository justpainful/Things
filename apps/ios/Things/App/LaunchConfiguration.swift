import Foundation
import SwiftUI

/// How this launch of the app is configured.
///
/// Everything that makes the Screenshot Tour deterministic enters here and nowhere else:
/// the seed dataset, the frozen clock, the pinned appearance, disabled animations. A
/// production launch takes none of these branches.
struct LaunchConfiguration: Sendable {

    /// `-UITesting` — load the fixed seed dataset into a throwaway library.
    var isUITesting: Bool
    /// `-ThingsAppearance light|dark` — pins the colour scheme for one pass of the tour.
    var appearance: ColorScheme?
    /// `-ThingsStartLocked` — open on the lock screen.
    var startsLocked: Bool
    /// `-ThingsPrivacyMode` — open with Privacy Mode already on.
    var privacyMode: Bool
    /// `-ThingsScreen <id>` — deep-link straight to one screen, so a tour pass does not
    /// have to navigate through four taps to photograph the fifth screen.
    var initialScreen: String?

    static let current = LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        isUITesting = arguments.contains("-UITesting")
        startsLocked = arguments.contains("-ThingsStartLocked")
        privacyMode = arguments.contains("-ThingsPrivacyMode")
        appearance = LaunchConfiguration.value(of: "-ThingsAppearance", in: arguments).flatMap {
            switch $0.lowercased() {
            case "light": return ColorScheme.light
            case "dark": return ColorScheme.dark
            default: return nil
            }
        }
        initialScreen = LaunchConfiguration.value(of: "-ThingsScreen", in: arguments)
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let next = arguments[index + 1]
        return next.hasPrefix("-") ? nil : next
    }

    /// The frozen present. Everything the UI renders as "2 hours ago" is measured from
    /// here, so a screenshot taken on Tuesday matches Monday's byte for byte.
    static let seedNowISO8601 = "2026-08-09T09:00:00.000Z"
}
