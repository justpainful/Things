import Foundation
import CryptoKit
import ThingsCore

/// The fixed dataset the Screenshot Tour photographs.
///
/// Two rules govern everything in this file.
///
/// **1. Obviously fictional.** No real domains (`.test` and `.example` only, which are
/// reserved by RFC 2606 and can never resolve), no plausible-looking keys, no real names.
/// A screenshot generated from a real library and attached to a public CI run is a
/// permanent public disclosure — that is the most plausible way this project leaks
/// something real, so there is no code path from a real library to an artifact at all.
/// `populate` writes `meta.seed_marker`, and the tour asserts it before taking a single
/// screenshot.
///
/// **2. Hostile, not flattering.** A seed that makes the design look good is worse than no
/// seed: layout breaks live in the long tail. So this contains a 60-character title, a
/// Thing with 40 fields, a 20 000-word note, an empty collection, a missing file reference
/// and a locked Thing — on purpose.
enum SeedData {

    /// **Not a secret.** A constant used only under `-UITesting`, to key a throwaway
    /// database full of obviously fictional data. It lives here rather than on `AppModel`
    /// so tests can reach it without crossing the main actor.
    static let uiTestingKey = SymmetricKey(data: Data(SHA256.hash(data: Data("things-ui-testing-fixed-key-not-a-secret".utf8))))

    static let deviceID = "01920000-0000-7000-8000-0000000d0001"
    static let computerDeviceID = "01920000-0000-7000-8000-0000000d0002"
    static let computerName = "STUDIO-PC"

    /// Exactly 60 characters. Counted by construction rather than by eye, because the point
    /// of this row is to break a layout that assumes titles are short.
    static let sixtyCharacterTitle = pad(
        "Zero Trust Access Policy Review For The Studio Team Archive",
        to: 60
    )

    static func pad(_ text: String, to length: Int) -> String {
        if text.count == length { return text }
        if text.count > length { return String(text.prefix(length)) }
        return text + String(repeating: "·", count: length - text.count)
    }

    // MARK: - Entry point

    static func populate(_ library: Library, clock: FixedClock) throws {
        try library.write { db in
            let alreadySeeded = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [MetaKey.seedMarker]
            )
            guard alreadySeeded == nil else { return }

            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
                arguments: [MetaKey.seedMarker, ThingsCoreInfo.seedMarkerValue]
            )

            // A second device, so device-scoped paths have somewhere to point.
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO device (id, name, platform, is_self, last_seen_at)
                VALUES (?, ?, 'windows', 0, ?)
                """,
                arguments: [computerDeviceID, computerName, clock.nowISO8601()]
            )

            let collections = try makeCollections(db, library: library)
            try makeCloudflare(db, library: library, collections: collections, clock: clock)
            try makeWebsite(db, library: library, collections: collections, clock: clock)
            try makeSteam(db, library: library, collections: collections, clock: clock)
            try makeHomeServer(db, library: library, collections: collections, clock: clock)
            try makeLongTitle(db, library: library, clock: clock)
            try makeFortyFields(db, library: library, clock: clock)
            try makeLongNote(db, library: library, clock: clock)
            try makeLocked(db, library: library, clock: clock)
            try makeMedia(db, library: library, clock: clock)
            try makeTrashed(db, library: library, clock: clock)
            try makeConflict(db, library: library)

            try SearchIndexer.rebuildAll(db, index: library.database.search, registry: library.registry)
        }
    }

    // MARK: - Collections

    private struct Collections {
        var nineteenEighty: String
        var development: String
        var gaming: String
        /// Deliberately never filled — the empty-collection layout case.
        var household: String
    }

    private static func makeCollections(_ db: Database, library: Library) throws -> Collections {
        let nineteenEighty = try library.collections.create(
            db, name: "1980", icon: ThingIcon(kind: .symbol, value: "sparkles")
        )
        let development = try library.collections.create(
            db, name: "Development", icon: ThingIcon(kind: .symbol, value: "hammer")
        )
        let gaming = try library.collections.create(
            db, name: "Gaming", icon: ThingIcon(kind: .symbol, value: "gamecontroller")
        )
        let household = try library.collections.create(
            db, name: "Household", icon: ThingIcon(kind: .symbol, value: "house")
        )
        return Collections(nineteenEighty: nineteenEighty.id,
                           development: development.id,
                           gaming: gaming.id,
                           household: household.id)
    }

    // MARK: - Things

    private static func makeCloudflare(_ db: Database, library: Library,
                                       collections: Collections, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: "Cloudflare", isPinned: true)
        try library.fields.addField(db, thingID: thing.id, variantID: "email",
                                    label: "Email", valueText: "studio@example.test")
        try library.fields.addField(db, thingID: thing.id, variantID: "username",
                                    label: "Username", valueText: "studio-admin")
        try library.fields.addField(db, thingID: thing.id, variantID: "password",
                                    label: "Account Password",
                                    secretPlaintext: "sample-not-a-real-password",
                                    dek: library.dek)
        try library.fields.addField(db, thingID: thing.id, variantID: "apiKey",
                                    label: "API Token",
                                    secretPlaintext: "sample-not-a-real-token",
                                    dek: library.dek)
        try library.fields.addField(db, thingID: thing.id, variantID: "dashboard",
                                    label: "Dashboard", valueText: "https://dash.example.test/login")
        try library.fields.addField(db, thingID: thing.id, variantID: "longText",
                                    label: "Notes",
                                    valueText: "Everything for the studio sits behind this account. Two-factor is on the recovery codes below.")
        try library.fields.addField(db, thingID: thing.id, variantID: "recoveryCodes",
                                    label: "Recovery Codes",
                                    secretPlaintext: "0000-0000\n1111-1111\n2222-2222",
                                    dek: library.dek)

        try library.tags.attach(db, tagName: "1980", to: thing.id)
        try library.tags.attach(db, tagName: "infrastructure", to: thing.id)
        try library.collections.add(db, thingID: thing.id, to: collections.development)
        try library.collections.add(db, thingID: thing.id, to: collections.nineteenEighty)
        try backdate(db, thingID: thing.id, days: 0, hours: 2, viewed: true, clock: clock)
    }

    private static func makeWebsite(_ db: Database, library: Library,
                                    collections: Collections, clock: FixedClock) throws {
        let cloudflare = try Thing.fetchOne(
            db, sql: "SELECT * FROM thing WHERE title = ? LIMIT 1", arguments: ["Cloudflare"]
        )
        let thing = try library.things.create(db, title: "1980 Website", isPinned: true)

        try library.fields.addField(db, thingID: thing.id, variantID: "github",
                                    label: "Repository", valueText: "https://github.test/studio/1980-site")
        try library.fields.addField(db, thingID: thing.id, variantID: "website",
                                    label: "Live Site", valueText: "https://1980.example.test")

        let ref = try library.fileRefs.create(db, deviceID: computerDeviceID,
                                              path: "D:\\Projects\\1980\\site",
                                              isDirectory: true,
                                              status: .present)
        try library.fields.addField(db, thingID: thing.id, variantID: "folder",
                                    label: "Source Folder", fileRefID: ref.id)

        if let cloudflare {
            try library.fields.addField(db, thingID: thing.id, variantID: "relation",
                                        label: "Uses", valueText: cloudflare.id)
        }
        try library.fields.addField(db, thingID: thing.id, variantID: "longText",
                                    label: "Notes",
                                    valueText: "Static build, deployed from the folder above. DNS lives in the Cloudflare Thing.")

        try library.tags.attach(db, tagName: "1980", to: thing.id)
        try library.collections.add(db, thingID: thing.id, to: collections.nineteenEighty)
        try library.collections.add(db, thingID: thing.id, to: collections.development)
        try backdate(db, thingID: thing.id, days: 0, hours: 5, viewed: true, clock: clock)
    }

    private static func makeSteam(_ db: Database, library: Library,
                                  collections: Collections, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: "Steam")
        try library.fields.addField(db, thingID: thing.id, variantID: "username",
                                    label: "Username", valueText: "player-one")
        try library.fields.addField(db, thingID: thing.id, variantID: "password",
                                    label: "Password",
                                    secretPlaintext: "sample-not-a-real-password",
                                    dek: library.dek)
        try library.fields.addField(db, thingID: thing.id, variantID: "steam",
                                    label: "Profile", valueText: "https://steamcommunity.test/id/player-one")
        try library.fields.addField(db, thingID: thing.id, variantID: "date",
                                    label: "Joined", valueText: "2019-04-11")
        try library.collections.add(db, thingID: thing.id, to: collections.gaming)
        try library.tags.attach(db, tagName: "games", to: thing.id)
        try backdate(db, thingID: thing.id, days: 1, hours: 0, viewed: true, clock: clock)
    }

    private static func makeHomeServer(_ db: Database, library: Library,
                                       collections: Collections, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: "Home Server")
        try library.fields.addField(db, thingID: thing.id, variantID: "ip",
                                    label: "Address", valueText: "10.0.0.42")
        try library.fields.addField(db, thingID: thing.id, variantID: "port",
                                    label: "SSH Port", valueText: "2222")
        try library.fields.addField(db, thingID: thing.id, variantID: "username",
                                    label: "Login", valueText: "operator")
        try library.fields.addField(db, thingID: thing.id, variantID: "sshKey",
                                    label: "Private Key",
                                    secretPlaintext: "SAMPLE-NOT-A-REAL-KEY",
                                    dek: library.dek)

        // The missing-file case. Status is `missing`, and the path belongs to the computer,
        // so the phone shows the device name and Copy Path rather than pretending it can
        // open it.
        let missing = try library.fileRefs.create(db, deviceID: computerDeviceID,
                                                  path: "D:\\Servers\\BeamNG\\Server1",
                                                  isDirectory: true,
                                                  status: .missing)
        try library.fields.addField(db, thingID: thing.id, variantID: "folder",
                                    label: "Game Server", fileRefID: missing.id)
        try library.fields.addField(db, thingID: thing.id, variantID: "command",
                                    label: "Start Command",
                                    valueText: "systemctl start beamng@server1")
        try library.collections.add(db, thingID: thing.id, to: collections.development)
        try backdate(db, thingID: thing.id, days: 3, hours: 0, viewed: true, clock: clock)
    }

    private static func makeLongTitle(_ db: Database, library: Library, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: sixtyCharacterTitle)
        try library.fields.addField(db, thingID: thing.id, variantID: "longText",
                                    label: "Why this exists",
                                    valueText: "This title is exactly sixty characters long so that every screen showing a title has to cope with one.")
        try library.fields.addField(db, thingID: thing.id, variantID: "plain",
                                    label: "A label that is itself unreasonably long for a single line",
                                    valueText: "…and a value that keeps going well past the width of any iPhone, including the largest one, at the largest Dynamic Type size.")
        try backdate(db, thingID: thing.id, days: 4, hours: 0, viewed: false, clock: clock)
    }

    /// Forty fields, spread across three sections. The variants come from the registry in
    /// file order, so this stays deterministic and automatically covers new field types.
    private static func makeFortyFields(_ db: Database, library: Library, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: "Everything, All At Once")

        let sectionA = try library.fields.addSection(db, thingID: thing.id, title: "Identity")
        let sectionB = try library.fields.addSection(db, thingID: thing.id, title: "Connection")
        let sectionC = try library.fields.addSection(db, thingID: thing.id, title: "Reference")
        let sections = [sectionA.id, sectionB.id, sectionC.id]

        let usable = library.registry.variants.filter { variant in
            // Skip the ones that need a real object or file behind them; those are covered
            // by their own seed Things.
            !["attachment", "path", "tagList", "relation"].contains(variant.kind.rawValue)
        }
        guard !usable.isEmpty else { return }

        for index in 0..<40 {
            let variant = usable[index % usable.count]
            let sectionID = sections[index % sections.count]
            let label = "\(variant.label) \(index + 1)"

            if variant.kind == .secret {
                let field = try library.fields.addField(db, thingID: thing.id, variantID: variant.id,
                                                        label: label, sectionID: sectionID)
                try library.fields.setSecret(db, fieldID: field.id,
                                             plaintext: "sample-not-a-real-secret-\(index)",
                                             dek: library.dek)
            } else {
                try library.fields.addField(db, thingID: thing.id, variantID: variant.id,
                                            label: label, sectionID: sectionID,
                                            valueText: sampleValue(for: variant, index: index))
            }
        }
        try backdate(db, thingID: thing.id, days: 5, hours: 0, viewed: false, clock: clock)
    }

    private static func sampleValue(for variant: FieldKindRegistry.Variant, index: Int) -> String? {
        switch variant.kind.rawValue {
        case "boolean": return index % 2 == 0 ? "1" : "0"
        case "number": return String(index * 7)
        case "date": return "2026-0\((index % 9) + 1)-1\(index % 9)"
        case "url": return "https://example.test/path/\(index)"
        case "color": return ["#2D6BE0", "#E07A2D", "#2DE08A", "#8A2DE0"][index % 4]
        case "code": return "echo \"sample command \(index)\""
        // `geo` and `money` live in value_json; an empty string in value_text would be a
        // second carrier for no benefit, so they ship as empty fields.
        case "geo", "money": return nil
        default: return "Sample value \(index)"
        }
    }

    /// Twenty thousand words. Generated rather than pasted, so the source file stays small
    /// and the content stays byte-identical between runs.
    private static func makeLongNote(_ db: Database, library: Library, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: "Notes From The Long Weekend")
        try library.fields.addField(db, thingID: thing.id, variantID: "plain",
                                    label: "Length", valueText: "20,000 words")
        try library.fields.addField(db, thingID: thing.id, variantID: "longText",
                                    label: "The Note", valueText: longNoteText(words: 20_000))
        try backdate(db, thingID: thing.id, days: 6, hours: 0, viewed: false, clock: clock)
    }

    static func longNoteText(words: Int) -> String {
        let vocabulary = [
            "studio", "archive", "shelf", "index", "cabinet", "ledger", "folder", "label",
            "drawer", "catalogue", "margin", "annotation", "reference", "inventory"
        ]
        var pieces: [String] = []
        pieces.reserveCapacity(words)
        for index in 0..<words {
            var word = vocabulary[index % vocabulary.count]
            if index % 17 == 0 { word = word.capitalized }
            if index % 23 == 22 { word += "." }
            pieces.append(word)
        }
        return pieces.joined(separator: " ")
    }

    private static func makeLocked(_ db: Database, library: Library, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: "Sealed Records", isLocked: true)
        try library.fields.addField(db, thingID: thing.id, variantID: "secret",
                                    label: "Contents",
                                    secretPlaintext: "sample-not-a-real-secret",
                                    dek: library.dek)
        try library.fields.addField(db, thingID: thing.id, variantID: "longText",
                                    label: "Note",
                                    valueText: "A locked Thing contributes nothing to search, Recents previews, or the app-switcher snapshot while it is locked.")
        try backdate(db, thingID: thing.id, days: 8, hours: 0, viewed: false, clock: clock)
    }

    /// Media: one attachment whose bytes really are stored, several whose bytes are not —
    /// the "chose not to download it" case, which must render as a greyed placeholder and
    /// never as a missing row.
    private static func makeMedia(_ db: Database, library: Library, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: "Studio Assets")

        let bytes = Data("THINGS-FICTIONAL-SEED-IMAGE-BYTES".utf8)
        let stored = try library.objects.store(db, data: bytes, mimeType: "image/png", width: 512, height: 512)
        try library.fields.addField(db, thingID: thing.id, variantID: "logo",
                                    label: "Studio Logo",
                                    valueJSON: nil,
                                    objectHash: stored.object.objectHash)

        for (index, variantID) in ["image", "image", "icon", "qr", "video"].enumerated() {
            try library.fields.addField(db, thingID: thing.id, variantID: variantID,
                                        label: "Asset \(index + 1)")
        }
        try library.fields.addField(db, thingID: thing.id, variantID: "pdf",
                                    label: "Brand Guidelines")
        try backdate(db, thingID: thing.id, days: 2, hours: 0, viewed: true, clock: clock)
    }

    private static func makeTrashed(_ db: Database, library: Library, clock: FixedClock) throws {
        let thing = try library.things.create(db, title: "Old Router Login")
        try library.fields.addField(db, thingID: thing.id, variantID: "ip",
                                    label: "Address", valueText: "192.168.0.1")
        try library.things.moveToTrash(db, id: thing.id)
    }

    /// One open conflict, so the "2 Versions" screen has something to show.
    private static func makeConflict(_ db: Database, library: Library) throws {
        guard let steam = try Thing.fetchOne(
            db, sql: "SELECT * FROM thing WHERE title = ? LIMIT 1", arguments: ["Steam"]
        ) else { return }
        guard var mine = try library.snapshot(db, entityType: .thing, entityID: steam.id) else { return }
        var theirs = mine
        mine["title"] = .string("Steam")
        theirs["title"] = .string("Steam (Family)")
        try library.conflicts.record(db, entityType: .thing, entityID: steam.id,
                                     local: mine, remote: theirs)
    }

    // MARK: - Helpers

    /// Places a Thing in the past without going through the oplog, so Recents and History
    /// have a believable spread and "2 hours ago" is stable across runs.
    private static func backdate(_ db: Database, thingID: String,
                                 days: Int, hours: Int, viewed: Bool, clock: FixedClock) throws {
        let base = Timestamp.milliseconds(fromISO8601: LaunchConfiguration.seedNowISO8601) ?? 0
        let offset = Int64(days) * Timestamp.millisecondsPerDay + Int64(hours) * 3_600_000
        let stamp = Timestamp.string(millisecondsSinceEpoch: base - offset)
        let viewedAt: String? = viewed ? stamp : nil
        try db.execute(
            sql: "UPDATE thing SET created_at = ?, updated_at = ?, viewed_at = ? WHERE id = ?",
            arguments: [stamp, stamp, viewedAt, thingID]
        )
    }
}
