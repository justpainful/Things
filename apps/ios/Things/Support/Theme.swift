import SwiftUI

/// Spacing rhythm, corner radii and the one place glass shapes are spelled.
///
/// Radii follow the concentric rule — `innerRadius = outerRadius − padding` — because
/// nested rounded shapes that do not share a centre look subtly wrong in a way people
/// notice without being able to name.
enum Theme {

    /// The palette. See `docs/03-DESIGN.md` §0 — the reference is Messages in dark mode.
    ///
    /// These deliberately wrap **UIKit system colours** rather than hardcoding hex. Two reasons:
    /// the values are then Apple's actual ones rather than someone's approximation of them, and
    /// they adapt to light/dark, Increase Contrast, and future OS revisions for free. On iOS in
    /// dark mode `systemBackground` *is* `#000000`, which is exactly the true black we want —
    /// a hand-written "soft black" like `#0d0d0f` is the tell of an app imitating the look
    /// instead of adopting it.
    enum Palette {

        // Surfaces
        static let canvas = Color(.systemBackground)              // #000 in dark
        static let raised = Color(.secondarySystemBackground)     // #1c1c1e in dark
        static let raisedHigher = Color(.tertiarySystemBackground) // #2c2c2e in dark
        static let grouped = Color(.systemGroupedBackground)

        // Text
        static let ink = Color(.label)
        static let inkSecondary = Color(.secondaryLabel)          // rgba(235,235,245,0.60)
        static let inkTertiary = Color(.tertiaryLabel)
        static let inkQuaternary = Color(.quaternaryLabel)

        // Fills — translucent grey, so they sit correctly on glass as well as on the canvas.
        static let fill = Color(.systemFill)
        static let fillSecondary = Color(.secondarySystemFill)
        static let fillTertiary = Color(.tertiarySystemFill)

        static let separator = Color(.separator)                  // grey-blue with alpha
        static let separatorOpaque = Color(.opaqueSeparator)

        /// Accent. Used **sparingly** — links, focus, destructive confirmation.
        /// Selection is neutral (see `selection`), never a blue wash: an accent-tinted selected
        /// row is the most common way a dark app stops reading as a system app.
        static let accent = Color(.systemBlue)
        static let destructive = Color(.systemRed)
        static let warning = Color(.systemOrange)
        static let success = Color(.systemGreen)

        /// Neutral selection fill.
        static let selection = Color(.systemFill)
    }

    enum Spacing {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let section: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 20
        static let inner: CGFloat = 12
        static let chip: CGFloat = 10
        static let thumbnail: CGFloat = 14
    }

    enum Size {
        static let icon: CGFloat = 34
        static let largeIcon: CGFloat = 56
        static let galleryTile: CGFloat = 108
        static let pinnedCard: CGFloat = 150
    }
}

/// The single place `ConcentricRectangle` is named.
///
/// It is an iOS 26 shape and this project's first compile happens on a CI runner, so if the
/// initialiser spelling is wrong the fix is one line here rather than a hunt through forty
/// view files.
enum ThingsShape {

    /// For floating glass controls that sit inside a container with its own radius.
    static var container: some Shape {
        ConcentricRectangle()
    }

    static func rounded(_ radius: CGFloat) -> some Shape {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension View {

    /// System Liquid Glass, `.regular`, **untinted**, always.
    ///
    /// `.clear` is banned in this app: Apple's guidance is to use it only over visually rich
    /// backgrounds like photo and video, and never to mix the two variants in one app.
    /// Things is text-dense, so `.regular` is correct everywhere.
    ///
    /// `.tint(…)` is also banned. The brief is **white liquid glass** (docs/03-DESIGN.md §0),
    /// and untinted `.regular` glass is already neutral/white — adding a tint is what turns
    /// system chrome into a themed third-party control. Tint would signal prominence, and if
    /// everything is tinted nothing is prominent.
    ///
    /// Note there is **no `isEnabled:` parameter** on `glassEffect` — guides carrying that
    /// signature were written during the 2025 beta cycle.
    func thingsGlass(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        glassEffect(.regular, in: ThingsShape.rounded(cornerRadius))
    }

    /// Glass on something that actually responds to touch. Interactive glass under a static
    /// label is a lie the user can feel.
    func thingsInteractiveGlass(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        glassEffect(.regular.interactive(), in: ThingsShape.rounded(cornerRadius))
    }

    /// Interactive glass on a control nested inside another rounded container, where the
    /// inner radius has to share a centre with the outer one. `ConcentricRectangle` is the
    /// API built for that rule, so the radius is never hand-computed.
    func thingsConcentricGlass() -> some View {
        glassEffect(.regular.interactive(), in: ThingsShape.container)
    }
}
