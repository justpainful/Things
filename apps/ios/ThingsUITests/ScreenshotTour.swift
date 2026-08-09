import XCTest

/// **The Screenshot Tour.**
///
/// This is how the project sees itself. There is no Mac, no simulator and no SwiftUI
/// preview on the developer's machine, so a change to a view is not "seen" until a robot in
/// GitHub's macOS cloud renders it and hands back a PNG. Each CI round trip costs 6–13
/// minutes, which is why one run captures *every* screen in *every* appearance mode instead
/// of one screen per run.
///
/// Four rules govern this file.
///
/// **1. `lifetime = .keepAlways` on every attachment.** `XCTAttachment.Lifetime`'s default
/// is `.deleteOnSuccess` — "an attachment should be discarded if its test passes
/// successfully". Passing tests throw their screenshots away by default, and it fails in
/// the most confusing possible direction: green build, empty zip.
///
/// **2. One boot, many launches.** With only five concurrent macOS jobs, a
/// `{light,dark} × {default,XXL}` matrix would burn four of them booting four simulators to
/// photograph the same app. Instead the appearance and the content size category are launch
/// arguments, and the tour relaunches the app in place.
///
/// **3. Determinism or nothing.** Fixed seed dataset, injected clock, animations off,
/// pinned locale and timezone. A pixel diff that flags forty false positives per run is
/// ignored within a week, and that quietly kills the entire quality loop.
///
/// **4. The tour never hard-fails on a missing control.** A screenshot of a broken screen is
/// evidence; an aborted run that captures nothing is not. The one exception is the seed
/// marker — if the app is not running on the fictional dataset, the tour stops immediately
/// rather than photograph someone's real library into a public artifact.
final class ScreenshotTour: XCTestCase {

    // MARK: - Modes

    struct Mode {
        let name: String
        let appearance: String
        let contentSize: String?

        var suffix: String {
            contentSize == nil ? appearance : "\(appearance)-xxl"
        }

        var launchArguments: [String] {
            var arguments = [
                "-UITesting",
                "-ThingsAppearance", appearance,
                // Pinned locale, so "9 Aug 2026" never becomes "August 9, 2026".
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ]
            if let contentSize {
                arguments += ["-UIPreferredContentSizeCategoryName", contentSize]
            }
            return arguments
        }

        /// Every screen is captured at these two.
        static let standard: [Mode] = [
            Mode(name: "light", appearance: "light", contentSize: nil),
            Mode(name: "dark", appearance: "dark", contentSize: nil)
        ]

        /// Only the screens where Dynamic Type actually breaks layout.
        static let accessibility: [Mode] = [
            Mode(name: "light-xxl", appearance: "light",
                 contentSize: "UICTContentSizeCategoryAccessibilityXXL"),
            Mode(name: "dark-xxl", appearance: "dark",
                 contentSize: "UICTContentSizeCategoryAccessibilityXXL")
        ]

        static let all: [Mode] = standard + accessibility
    }

    private static let launchEnvironment = ["TZ": "UTC"]
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - The tour

    /// Full walk at the two standard sizes; a short stress walk at the accessibility sizes.
    ///
    /// Four full passes cost 30 minutes and blew the job's time limit. The accessibility
    /// passes were most of that and earned the least: Dynamic Type breaks on a handful of
    /// dense screens, and photographing Settings at XXL for the fourth time proves nothing.
    /// This keeps the accessibility signal exactly where layout actually fails and cuts the
    /// run from twelve app launches to eight.
    func testScreenshotTour() {
        for mode in Mode.standard {
            walkMainFlow(mode)
            walkLockScreen(mode)
            walkPrivacyMode(mode)
        }
        for mode in Mode.accessibility {
            walkStressScreens(mode)
        }
    }

    /// The screens where Dynamic Type actually breaks things: dense rows, long titles,
    /// two-column cards, and anything with a trailing timestamp.
    private func walkStressScreens(_ mode: Mode) {
        launch(mode)
        assertSeedDataset()

        snap(1, "home", mode)
        homeScrolledToBottom(mode)

        if tapText("Cloudflare") {
            snap(3, "thing-detail-fields", mode)
            back()
        }
        if tapText("Everything, All At Once") {
            snap(7, "thing-detail-sections", mode)
            back()
        }
        tapTab("Search")
        snap(13, "search-idle", mode)
        tapTab("Collections")
        snap(16, "collections", mode)

        app.terminate()
    }

    /// Scrolls Home to the very bottom and photographs it.
    ///
    /// This exists to answer one question that a top-of-scroll screenshot cannot: is the last
    /// row reachable, or is it stranded under the floating tab bar? Content passing *behind*
    /// glass is Apple's intended behaviour; content you can never scroll into the clear is a
    /// bug. Those two look identical at the top of a list, which is why the first three
    /// attempts at this were guesses.
    private func homeScrolledToBottom(_ mode: Mode) {
        for _ in 0..<6 { app.swipeUp() }
        // Index 1, not 2: this belongs next to Home in a sorted listing, and index 2 is
        // already All Things. Renumbering twenty-seven downstream snaps to insert one
        // screenshot would be a much better way to lose a screenshot than to gain one.
        snap(1, "home-scrolled-bottom", mode)
        for _ in 0..<7 { app.swipeDown() }
    }

    // MARK: - Pass 1 — everything reachable from an unlocked app

    private func walkMainFlow(_ mode: Mode) {
        launch(mode)
        assertSeedDataset()

        snap(1, "home", mode)
        homeScrolledToBottom(mode)

        // All Things
        if tap(identifier: "home.allThings") {
            snap(2, "all-things", mode)
            back()
        }

        // Thing detail — a Thing with real fields, including secrets.
        if tapText("Cloudflare") {
            snap(3, "thing-detail-fields", mode)

            // Field quick actions (long press on a field row).
            let firstCell = app.cells.element(boundBy: 1)
            if firstCell.waitForExistence(timeout: 3) {
                firstCell.press(forDuration: 1.1)
                snap(4, "field-quick-actions", mode)
                dismissOverlay()
            }

            // Add Field sheet.
            if tap(identifier: "detail.addField") {
                snap(5, "add-field-sheet", mode)
                tapFirst(label: "Cancel")
            }

            // History for this Thing.
            if tap(identifier: "detail.history") {
                snap(6, "history", mode)
                back()
            }
            back()
        }

        // A Thing with 40 fields across three named sections.
        if tapText("Everything, All At Once") {
            snap(7, "thing-detail-sections", mode)
            back()
        }

        // Long content: the 60-character title and the 20 000-word note.
        if tapText("Notes From The Long Weekend") {
            snap(8, "thing-detail-long-note", mode)
            back()
        }

        // Media gallery and the single-item viewer.
        if tapText("Studio Assets") {
            if tap(identifier: "detail.gallery") {
                snap(9, "media-gallery", mode)
                let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'gallery.tile.'")).firstMatch
                if tile.waitForExistence(timeout: 3) {
                    tile.tap()
                    snap(10, "photo-viewer", mode)
                    back()
                }
                back()
            }
            back()
        }

        // New Thing from a template.
        if tap(identifier: "home.add") {
            snap(11, "new-thing-templates", mode)
            tapFirst(label: "Cancel")
        }

        // Long-press quick actions on a list row.
        let recentRow = app.cells.element(boundBy: 1)
        if recentRow.waitForExistence(timeout: 3) {
            recentRow.press(forDuration: 1.1)
            snap(12, "quick-actions", mode)
            dismissOverlay()
        }

        // Search: idle, then results with a filter chip on.
        tapTab("Search")
        snap(13, "search-idle", mode)
        if tapChip("accounts") {
            snap(14, "search-results-chips", mode)
            _ = tapChip("accounts")
        }
        typeIntoSearch("zzzz-no-such-thing")
        snap(15, "search-empty", mode)

        // Collections, and one collection's contents.
        tapTab("Collections")
        snap(16, "collections", mode)
        if tapText("Household") {
            snap(17, "collection-empty", mode)
            back()
        }
        if tapText("Development") {
            snap(18, "collection-detail", mode)
            back()
        }

        // Settings and everything hanging off it.
        tapTab("Things")
        if tap(identifier: "home.settings") {
            snap(19, "settings", mode)

            if tap(identifier: "settings.trash") {
                snap(20, "trash", mode)
                back()
            }
            if tap(identifier: "settings.conflicts") {
                snap(21, "conflicts-two-versions", mode)
                back()
            }
            if tap(identifier: "settings.sync") {
                snap(22, "sync-pairing", mode)
                back()
            }
            if tap(identifier: "settings.diagnostics") {
                snap(23, "diagnostics", mode)
                tapFirst(label: "Done")
            }
            back()
        }

        app.terminate()
    }

    // MARK: - Pass 2 — the lock screen

    private func walkLockScreen(_ mode: Mode) {
        launch(mode, extraArguments: ["-ThingsStartLocked"])
        _ = app.otherElements["lock.root"].waitForExistence(timeout: 8)
        snap(24, "lock", mode)

        // Two digits in, so the tour also captures the partially-filled state.
        _ = tap(identifier: "lock.digit.1")
        _ = tap(identifier: "lock.digit.2")
        snap(25, "lock-entering", mode)

        app.terminate()
    }

    // MARK: - Pass 3 — Privacy Mode

    private func walkPrivacyMode(_ mode: Mode) {
        launch(mode, extraArguments: ["-ThingsPrivacyMode"])
        assertSeedDataset()
        snap(26, "privacy-mode-home", mode)
        if tapText("Cloudflare") {
            snap(27, "privacy-mode-detail", mode)
        }
        app.terminate()
    }

    // MARK: - Launching

    private func launch(_ mode: Mode, extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = mode.launchArguments + extraArguments
        app.launchEnvironment = ScreenshotTour.launchEnvironment
        app.launch()
    }

    /// The one assertion that is allowed to stop the run.
    ///
    /// A screenshot of a real library attached to a public CI run is a permanent public
    /// disclosure. If the marker is not there, the app is not on the fictional seed, and
    /// nothing gets photographed.
    private func assertSeedDataset() {
        let marker = app.staticTexts["seed.marker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 12),
                      "The seed marker is absent — refusing to photograph a library that may be real.")
    }

    // MARK: - Capture

    /// `NN-screen-mode.png`, zero padded so the files sort the way the tour walked them.
    private func snap(_ index: Int, _ screen: String, _ mode: Mode) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d", index) + "-\(screen)-\(mode.suffix)"
        // REQUIRED. The default lifetime discards attachments when the test passes.
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Resilient interaction
    //
    // Every helper returns whether it found what it was looking for. A missing control
    // produces a screenshot of whatever is on screen and a printed note, never an abort.

    /// `isHittable` is NOT safe to read on an arbitrary element.
    ///
    /// When an element's frame is degenerate, XCUITest cannot compute an activation point and
    /// **records a test failure** rather than returning `false`:
    ///
    ///     Failed to determine hittability of "search.chip.accounts" Button:
    ///     Activation point invalid and no suggested hit points based on element frame
    ///
    /// That is what killed the first real tour: one off-screen chip aborted the run at
    /// screenshot 14 of 88, taking every dark-mode and every XXL pass with it. Guarding with
    /// `if !element.isHittable` does not help, because the crash is in *reading the property*.
    ///
    /// So: check the geometry ourselves first, and only ask XCUITest about hittability once we
    /// know the frame is real and on screen.
    private func canTouch(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        let window = app.windows.firstMatch.frame
        guard window.width > 0, window.intersects(frame) else { return false }
        return element.isHittable
    }

    @discardableResult
    private func tap(identifier: String) -> Bool {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard element.waitForExistence(timeout: 2) else {
            print("[tour] no element for identifier '\(identifier)'")
            return false
        }
        // At AccessibilityXXL most of these screens are two or three phone-heights tall, so
        // a control that exists is routinely below the fold — `Settings ▸ Sync` and
        // `Settings ▸ Diagnostics` certainly are. Scroll to it rather than quietly dropping
        // the screenshot, which is the failure mode that leaves a green build with a hole
        // in the middle of the tour.
        var attempts = 0
        while !canTouch(element) && attempts < 3 {
            app.swipeUp()
            attempts += 1
        }
        guard canTouch(element) else {
            print("[tour] identifier '\(identifier)' never became hittable")
            return false
        }
        element.tap()
        return true
    }

    @discardableResult
    private func tapText(_ text: String) -> Bool {
        // `.firstMatch` is not optional here. A pinned Thing appears twice on Home — once in
        // the Pinned shelf and once in Recent — and resolving an ambiguous `XCUIElement`
        // raises "Multiple matching elements found" instead of picking one.
        let element = app.staticTexts[text].firstMatch
        guard element.waitForExistence(timeout: 2) else {
            print("[tour] no element with text '\(text)'")
            return false
        }
        if canTouch(element) {
            element.tap()
        } else {
            // A row that is scrolled off, or clipped by a long title: nudge it into view.
            app.swipeUp()
            guard element.waitForExistence(timeout: 2), canTouch(element) else { return false }
            element.tap()
        }
        return true
    }

    @discardableResult
    private func tapFirst(label: String) -> Bool {
        let element = app.buttons[label].firstMatch
        guard element.waitForExistence(timeout: 3), canTouch(element) else {
            print("[tour] no button labelled '\(label)'")
            return false
        }
        element.tap()
        return true
    }

    /// The filter chips live in a horizontal scroll view that is wider than the screen at
    /// every Dynamic Type size — "Accounts" is the eighth chip, roughly 640pt in on a 402pt
    /// screen, and far worse at AccessibilityXXL. `tap(identifier:)` would find it, see
    /// `isHittable == false`, and silently skip the screenshot. So scroll to it first.
    @discardableResult
    private func tapChip(_ id: String) -> Bool {
        let element = app.descendants(matching: .any)
            .matching(identifier: "search.chip.\(id)").firstMatch
        guard element.waitForExistence(timeout: 2) else {
            print("[tour] no chip '\(id)'")
            return false
        }
        let row = app.descendants(matching: .any).matching(identifier: "search.chips").firstMatch
        var attempts = 0
        while !canTouch(element) && attempts < 4 {
            if row.exists {
                row.swipeLeft()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeLeft()
            } else {
                break
            }
            attempts += 1
        }
        guard canTouch(element) else {
            print("[tour] chip '\(id)' never became hittable")
            return false
        }
        element.tap()
        return true
    }

    private func tapTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        if tab.waitForExistence(timeout: 3), canTouch(tab) {
            tab.tap()
            return
        }
        // The tab bar minimises on scroll down; scrolling back up brings it in.
        app.swipeDown()
        if tab.waitForExistence(timeout: 2), canTouch(tab) {
            tab.tap()
        } else {
            print("[tour] could not reach the '\(title)' tab")
        }
    }

    private func back() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if canTouch(backButton) {
            backButton.tap()
        }
    }

    /// Dismisses a context menu or a popover without needing to know where it is.
    private func dismissOverlay() {
        let corner = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        corner.tap()
    }

    private func typeIntoSearch(_ text: String) {
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 2) else {
            print("[tour] no search field")
            return
        }
        field.tap()
        field.typeText(text)
    }
}
