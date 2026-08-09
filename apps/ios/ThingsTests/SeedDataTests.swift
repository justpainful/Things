import XCTest
import ThingsCore
@testable import Things

/// Unit tests that run before the simulator is asked to do anything expensive.
///
/// Their job is narrow: catch the things that would silently ruin a Screenshot Tour — a
/// seed that is not actually hostile, a relative date that drifts, a launch flag that stops
/// being parsed.
final class SeedDataTests: XCTestCase {

    func testTitleIsExactlySixtyCharacters() {
        XCTAssertEqual(SeedData.sixtyCharacterTitle.count, 60)
    }

    func testLongNoteIsTwentyThousandWords() {
        let note = SeedData.longNoteText(words: 20_000)
        XCTAssertEqual(note.approximateWordCount, 20_000)
    }

    func testSeedIsDeterministic() throws {
        let first = try seedTitles()
        let second = try seedTitles()
        XCTAssertEqual(first, second, "the seed must produce identical content on every run")
    }

    func testSeedContainsTheHostileCases() throws {
        let library = try makeSeededLibrary()
        try library.read { db in
            let titles = try String.fetchAll(db, sql: "SELECT title FROM thing ORDER BY title")

            XCTAssertTrue(titles.contains(SeedData.sixtyCharacterTitle), "missing the 60-character title")

            let locked = try Int.fetchOne(db, sql: "SELECT count(*) FROM thing WHERE is_locked = 1") ?? 0
            XCTAssertGreaterThan(locked, 0, "missing a locked Thing")

            let trashed = try Int.fetchOne(db, sql: "SELECT count(*) FROM thing WHERE deleted_at IS NOT NULL") ?? 0
            XCTAssertGreaterThan(trashed, 0, "missing a deleted Thing")

            let missingRefs = try Int.fetchOne(db, sql: "SELECT count(*) FROM file_ref WHERE status = 'missing'") ?? 0
            XCTAssertGreaterThan(missingRefs, 0, "missing a missing file reference")

            let emptyCollections = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM collection
                WHERE is_smart = 0 AND id NOT IN (SELECT collection_id FROM collection_member)
                """) ?? 0
            XCTAssertGreaterThan(emptyCollections, 0, "missing an empty collection")

            let widest = try Int.fetchOne(db, sql: """
                SELECT MAX(c) FROM (SELECT count(*) AS c FROM field GROUP BY thing_id)
                """) ?? 0
            XCTAssertGreaterThanOrEqual(widest, 40, "missing a Thing with 40 fields")

            let marker = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?",
                                             arguments: [MetaKey.seedMarker])
            XCTAssertEqual(marker, ThingsCoreInfo.seedMarkerValue)
        }
    }

    /// The security property the whole seed exists to keep honest.
    func testNoSeedSecretIsSearchableByValue() throws {
        let library = try makeSeededLibrary()
        try library.read { db in
            let hits = try library.search.search(db, query: SearchQuery.parse("sample-not-a-real-password"))
            XCTAssertTrue(hits.isEmpty, "a secret value reached the search index")
        }
    }

    // MARK: - Helpers

    private func makeSeededLibrary() throws -> Library {
        let clock = FixedClock(startISO8601: LaunchConfiguration.seedNowISO8601, stepMilliseconds: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("things-seed-tests-\(UUID().uuidString)", isDirectory: true)
        let locations = Library.Locations(root: root)
        let library = try Library.open(locations: locations,
                                       dek: SeedData.uiTestingKey,
                                       deviceID: SeedData.deviceID,
                                       deviceName: "Test",
                                       clock: clock)
        try library.installSmartViewsIfNeeded()
        try SeedData.populate(library, clock: clock)
        return library
    }

    private func seedTitles() throws -> [String] {
        let library = try makeSeededLibrary()
        return try library.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM thing ORDER BY title")
        }
    }
}

final class FormattingTests: XCTestCase {

    private let now = Timestamp.milliseconds(fromISO8601: "2026-08-09T09:00:00.000Z") ?? 0

    func testRelativeTime() {
        XCTAssertEqual(RelativeTime.string(fromISO8601: "2026-08-09T08:00:00.000Z", nowMilliseconds: now),
                       "1 hour ago")
        XCTAssertEqual(RelativeTime.string(fromISO8601: "2026-08-09T07:00:00.000Z", nowMilliseconds: now),
                       "2 hours ago")
        XCTAssertEqual(RelativeTime.string(fromISO8601: "2026-08-08T07:00:00.000Z", nowMilliseconds: now),
                       "Yesterday")
        XCTAssertEqual(RelativeTime.string(fromISO8601: nil, nowMilliseconds: now), "—")
    }

    func testAbsoluteDayIsLocaleIndependent() {
        XCTAssertEqual(RelativeTime.absoluteDay("2026-08-09T09:00:00.000Z"), "9 Aug 2026")
    }

    func testByteSizes() {
        XCTAssertEqual(ByteSize.string(512), "512 bytes")
        XCTAssertEqual(ByteSize.string(2048), "2.0 KB")
        XCTAssertEqual(ByteSize.string(5 * 1024 * 1024), "5.0 MB")
    }
}

final class LaunchConfigurationTests: XCTestCase {

    func testFlags() {
        let configuration = LaunchConfiguration(arguments: [
            "Things", "-UITesting", "-ThingsAppearance", "dark", "-ThingsStartLocked"
        ])
        XCTAssertTrue(configuration.isUITesting)
        XCTAssertTrue(configuration.startsLocked)
        XCTAssertFalse(configuration.privacyMode)
        XCTAssertEqual(configuration.appearance, .dark)
    }

    func testProductionLaunchTakesNoTestBranch() {
        let configuration = LaunchConfiguration(arguments: ["Things"])
        XCTAssertFalse(configuration.isUITesting)
        XCTAssertNil(configuration.appearance)
        XCTAssertNil(configuration.initialScreen)
    }

    func testAppearanceFlagWithoutValueIsIgnored() {
        let configuration = LaunchConfiguration(arguments: ["Things", "-ThingsAppearance", "-UITesting"])
        XCTAssertNil(configuration.appearance)
        XCTAssertTrue(configuration.isUITesting)
    }
}
