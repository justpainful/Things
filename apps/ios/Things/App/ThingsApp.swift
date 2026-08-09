import SwiftUI
import UIKit
import ThingsCore

@main
struct ThingsApp: App {

    @State private var model = AppModel()

    /// Appearance preference. **Dark is the default, not "follow the system."**
    ///
    /// The brief is Messages in dark mode (docs/03-DESIGN.md §0), and on a phone set to light
    /// the app would otherwise open white — which is simply not the app that was designed. The
    /// user can still choose in Settings, and the Screenshot Tour pins each pass explicitly via
    /// `-ThingsAppearance`, which takes precedence over this.
    @AppStorage("appearance") private var appearancePreference: String = "dark"

    private var colorScheme: ColorScheme? {
        if let pinned = model.configuration.appearance { return pinned }
        switch appearancePreference {
        case "light":  return .light
        case "system": return nil
        default:       return .dark
        }
    }

    init() {
        if LaunchConfiguration.current.isUITesting {
            // Animations off. A pixel diff against an in-flight spring is noise, and noise
            // is what kills a visual-review loop.
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(colorScheme)
                .task { model.bootstrapIfNeeded() }
        }
    }
}

struct RootView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                LaunchPlaceholder()
            case .setup:
                LockScreenView(mode: .create)
            case .locked:
                LockScreenView(mode: .unlock)
            case .unlocked:
                MainTabs()
            case .failed(let message):
                FailureView(message: message)
            }
        }
        // No custom background anywhere in the navigation containers below: Apple is
        // explicit that they interfere with system glass and the scroll edge effect.
        .animation(model.configuration.isUITesting ? nil : .default, value: model.phase)
        .overlay(alignment: .topLeading) { seedMarker }
    }

    /// Present only under `-UITesting`, and only when the open library really is the
    /// fictional seed. The Screenshot Tour asserts this before it takes a single frame:
    /// there must be no path from a real library to a public CI artifact.
    ///
    /// Sized to a hairline at 0.1% opacity, so it is in the accessibility tree and not in
    /// the picture.
    @ViewBuilder
    private var seedMarker: some View {
        if model.configuration.isUITesting {
            Text(ThingsCoreInfo.seedMarkerValue)
                .font(.system(size: 1))
                .opacity(0.001)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityIdentifier("seed.marker")
        }
    }
}

/// The shell.
///
/// `Tab(role: .search)` in its standard-tab style, not button style — the HIG recommends
/// the dedicated landing page when you want to show suggestions before the user types,
/// which is exactly what Search idle does here.
struct MainTabs: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        // Tab bar buttons are queried by their visible titles in the Screenshot Tour:
        // `TabContent` is not a `View`, so `.accessibilityIdentifier` cannot be attached
        // to a `Tab` the way it can to everything else in this app.
        TabView {
            Tab("Things", systemImage: "square.stack") {
                HomeView()
            }

            Tab("Collections", systemImage: "folder") {
                CollectionsView()
            }

            Tab(role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(.accentColor)
    }
}

struct LaunchPlaceholder: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "square.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Things")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailureView: View {

    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text("Things could not open")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
