import Foundation
import XCTest
import GRDB
@testable import ThingsCore

final class RegistryParityTests: XCTestCase {

    /// The bundled copies of the normative spec files must be byte-identical to `spec/`.
    /// Copies drift; this is the tripwire.
    func testBundledSpecFilesMatchTheSpecDirectory() throws {
        guard let spec = TestSupport.specDirectory else {
            throw XCTSkip("spec/ not found from \(#filePath)")
        }
        for name in ["schema.sql", "field-kinds.json"] {
            let normative = try Data(contentsOf: spec.appendingPathComponent(name))
            let components = name.split(separator: ".")
            let bundled = try BundledResource.data(named: String(components[0]),
                                                   extension: String(components[1]))
            XCTAssertEqual(bundled, normative, "\(name) has drifted from spec/\(name)")
        }
    }

    func testRegistryLoads() throws {
        let registry = try TestSupport.registry()
        XCTAssertGreaterThan(registry.variants.count, 30)
        XCTAssertNotNil(registry.variant("password"))
        XCTAssertEqual(registry.variant("password")?.kind, .secret)
        XCTAssertTrue(registry.defaultIsSecret(forVariant: "password"))
        XCTAssertFalse(registry.defaultIsSecret(forVariant: "username"))
    }

    func testEveryVariantNamesAKnownKind() throws {
        let registry = try TestSupport.registry()
        for variant in registry.variants {
            XCTAssertNotNil(registry.kind(variant.kind), "variant \(variant.id) has unknown kind \(variant.kind)")
        }
    }

    func testEveryVariantActionIsRegistered() throws {
        let registry = try TestSupport.registry()
        for variant in registry.variants {
            for action in variant.actions {
                XCTAssertNotNil(registry.actions[action], "variant \(variant.id) uses unknown action '\(action)'")
            }
        }
    }

    func testURLVariantDetection() throws {
        let registry = try TestSupport.registry()
        XCTAssertEqual(registry.detectURLVariant("https://github.com/example/repo")?.id, "github")
        XCTAssertEqual(registry.detectURLVariant("https://youtu.be/abc")?.id, "youtube")
        XCTAssertEqual(registry.detectURLVariant("https://example.test/page")?.id, "website")
    }

    func testTemplatesReferenceRealVariants() throws {
        let registry = try TestSupport.registry()
        for template in registry.templates {
            for section in template.sections {
                for field in section.fields {
                    XCTAssertNotNil(registry.variant(field.variant),
                                    "template \(template.id) uses unknown variant '\(field.variant)'")
                }
            }
        }
    }
}

final class SchemaTests: XCTestCase {

    func testStatementSplitter() {
        let sql = """
        -- a comment with a ; semicolon-looking thing
        CREATE TABLE a (x TEXT DEFAULT 'has ; inside');
        CREATE TABLE b (y TEXT);
        """
        let statements = SchemaSQL.statements(in: sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].hasPrefix("CREATE TABLE a"))
        XCTAssertTrue(statements[1].hasPrefix("CREATE TABLE b"))
    }

    func testSchemaContainsEveryTable() throws {
        let library = try TestSupport.makeLibrary()
        let names = try library.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for expected in ["change", "collection", "collection_member", "conflict", "device",
                         "field", "file_ref", "meta", "object", "section", "sync_state",
                         "tag", "thing", "thing_tag", "thumbnail"] {
            XCTAssertTrue(names.contains(expected), "missing table \(expected)")
        }
    }

    func testDiagnosticsAreReported() throws {
        let library = try TestSupport.makeLibrary()
        // Not asserting FTS5 is present — that is exactly the unverified thing. Asserting
        // the diagnostic ran and the app chose an index accordingly.
        XCTAssertFalse(library.diagnostics.sqliteVersion.isEmpty)
        XCTAssertEqual(library.database.search.name, library.diagnostics.hasFTS5 ? "fts5" : "like")
        print(library.diagnostics.logLine)
    }

    func testExactlyOneValueCarrierIsEnforced() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Carrier check")
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                    INSERT INTO field (id, thing_id, sort_order, kind, label, value_text, value_json,
                                       is_secret, created_at, updated_at, version_vector)
                    VALUES (?, ?, 1, 'text', 'Both', 'a', '{}', 0, '', '', '{}')
                    """,
                    arguments: [UUIDv7.generate(clock: library.clock), thing.id]
                )
            )
        }
    }
}

final class ThingRepositoryTests: XCTestCase {

    func testCreateReadUpdateTrash() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "1980 Website")
            XCTAssertEqual(try library.things.find(db, id: thing.id)?.title, "1980 Website")

            try library.things.rename(db, id: thing.id, title: "1980 Website (renamed)")
            XCTAssertEqual(try library.things.find(db, id: thing.id)?.title, "1980 Website (renamed)")

            try library.things.setPinned(db, id: thing.id, true)
            XCTAssertEqual(try library.things.pinned(db).count, 1)

            try library.things.moveToTrash(db, id: thing.id)
            XCTAssertEqual(try library.things.all(db).count, 0)
            XCTAssertEqual(try library.things.trashed(db).count, 1)

            try library.things.restoreFromTrash(db, id: thing.id)
            XCTAssertEqual(try library.things.all(db).count, 1)
        }
    }

    func testVersionVectorAdvancesOnEveryEdit() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Vector")
            let first = try library.things.find(db, id: thing.id)!.vector
            try library.things.rename(db, id: thing.id, title: "Vector 2")
            let second = try library.things.find(db, id: thing.id)!.vector
            XCTAssertEqual(second.compare(to: first), .dominates)
        }
    }

    func testViewingIsNotAnEdit() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Read me")
            let before = try library.things.find(db, id: thing.id)!
            try library.things.markViewed(db, id: thing.id)
            let after = try library.things.find(db, id: thing.id)!
            XCTAssertEqual(before.updatedAt, after.updatedAt)
            XCTAssertEqual(before.versionVector, after.versionVector)
            XCTAssertNotNil(after.viewedAt)
        }
    }

    func testTemplateCreatesFieldsWithEmptyValues() throws {
        let library = try TestSupport.makeLibrary()
        let registry = try TestSupport.registry()
        let template = try XCTUnwrap(registry.template("account"))
        try library.write { db in
            let thing = try library.things.createFromTemplate(db, template: template, title: "New Account")
            let fields = try library.fields.fields(db, thingID: thing.id)
            XCTAssertEqual(fields.count, template.fieldCount)
            XCTAssertTrue(fields.allSatisfy { !$0.hasValue })
            XCTAssertTrue(fields.contains { $0.variant == "password" && $0.isSecret })
        }
    }

    func testBacklinksComeFromTheRelationIndex() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let cloudflare = try library.things.create(db, title: "Cloudflare")
            let website = try library.things.create(db, title: "1980 Website")
            try library.fields.addField(db, thingID: website.id, variantID: "relation",
                                        label: "Uses", valueText: cloudflare.id)
            let detail = try XCTUnwrap(library.things.detail(db, id: cloudflare.id))
            XCTAssertEqual(detail.backlinks.map { $0.id }, [website.id])
        }
    }
}

final class FieldRepositoryTests: XCTestCase {

    func testSecretIsNeverStoredInTheClear() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Account")
            let field = try library.fields.addField(db, thingID: thing.id, variantID: "password",
                                                    label: "Password",
                                                    secretPlaintext: "fictional-value-0000",
                                                    dek: library.dek)
            XCTAssertTrue(field.isSecret)
            XCTAssertNil(field.valueText)
            XCTAssertNil(field.valueJSON)
            XCTAssertNotNil(field.valueCipher)

            let revealed = try library.fields.revealSecret(db, fieldID: field.id, dek: library.dek)
            XCTAssertEqual(revealed, "fictional-value-0000")
        }
    }

    func testOplogNeverContainsSecretPlaintext() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Account")
            let field = try library.fields.addField(db, thingID: thing.id, variantID: "password", label: "Password")
            try library.fields.setSecret(db, fieldID: field.id, plaintext: "fictional-value-1111", dek: library.dek)

            let blobs = try String.fetchAll(db, sql: "SELECT attrs_json || COALESCE(prev_json, '') FROM change")
            for blob in blobs {
                XCTAssertFalse(blob.contains("fictional-value-1111"), "the oplog leaked a secret")
            }
        }
    }

    func testSearchIndexNeverContainsSecretValues() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Steam")
            _ = try library.fields.addField(db, thingID: thing.id, variantID: "password",
                                            label: "Account Password",
                                            secretPlaintext: "fictional-value-2222",
                                            dek: library.dek)
            let hits = try library.search.search(db, query: SearchQuery.parse("fictional-value-2222"))
            XCTAssertTrue(hits.isEmpty)

            // The label is still findable, which is the point of "has:password".
            let byLabel = try library.search.search(db, query: SearchQuery.parse("Account Password"))
            XCTAssertEqual(byLabel.map { $0.thingID }, [thing.id])
        }
    }

    func testFractionalReorderTouchesOneRow() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Ordering")
            let a = try library.fields.addField(db, thingID: thing.id, variantID: "plain", label: "A")
            let b = try library.fields.addField(db, thingID: thing.id, variantID: "plain", label: "B")
            let c = try library.fields.addField(db, thingID: thing.id, variantID: "plain", label: "C")

            try library.fields.move(db, fieldID: c.id, toSection: nil, after: a, before: b)
            let ordered = try library.fields.fields(db, thingID: thing.id).map { $0.label }
            XCTAssertEqual(ordered, ["A", "C", "B"])
        }
    }

    func testDuplicateURLDetection() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let project = try library.things.create(db, title: "GitHub Project")
            try library.fields.addField(db, thingID: project.id, variantID: "github",
                                        label: "Repository", valueText: "https://github.test/example")
            let matches = try library.fields.thingsContaining(db, url: "https://github.test/example")
            XCTAssertEqual(matches.map { $0.id }, [project.id])
        }
    }
}

final class SearchTests: XCTestCase {

    func testQueryParsing() {
        let query = SearchQuery.parse("tag:1980 type:image \"exact phrase\" -excluded cloudflare is:pinned")
        XCTAssertEqual(query.terms, ["cloudflare"])
        XCTAssertEqual(query.phrases, ["exact phrase"])
        XCTAssertEqual(query.excludedTerms, ["excluded"])
        XCTAssertTrue(query.filters.contains(SearchQuery.Filter(key: "tag", value: "1980")))
        XCTAssertTrue(query.filters.contains(SearchQuery.Filter(key: "type", value: "image")))
        XCTAssertTrue(query.filters.contains(SearchQuery.Filter(key: "is", value: "pinned")))
    }

    func testUnknownOperatorStaysFreeText() {
        let query = SearchQuery.parse("ratio:2")
        XCTAssertEqual(query.terms, ["ratio:2"])
        XCTAssertTrue(query.filters.isEmpty)
    }

    func testNegatedFilter() {
        let query = SearchQuery.parse("-has:tag")
        XCTAssertEqual(query.filters.first, SearchQuery.Filter(key: "has", value: "tag", negated: true))
    }

    func testCanonicalRoundTrip() {
        let original = SearchQuery.parse("is:pinned tag:1980 cloudflare")
        XCTAssertEqual(SearchQuery.parse(original.canonical).canonical, original.canonical)
    }

    func testSizeFilter() {
        XCTAssertEqual(SizeFilter.parse(">50mb")?.bytes, 50 * 1024 * 1024)
        XCTAssertEqual(SizeFilter.parse(">50mb")?.comparison, .greater)
        XCTAssertEqual(SizeFilter.parse("<1kb")?.bytes, 1024)
    }

    func testFiltersRunAgainstTheDatabase() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let pinned = try library.things.create(db, title: "Pinned Thing", isPinned: true)
            _ = try library.things.create(db, title: "Ordinary Thing")
            try library.tags.attach(db, tagName: "1980", to: pinned.id)

            XCTAssertEqual(try library.search.search(db, query: SearchQuery.parse("is:pinned")).map { $0.thingID },
                           [pinned.id])
            XCTAssertEqual(try library.search.search(db, query: SearchQuery.parse("tag:1980")).map { $0.thingID },
                           [pinned.id])
            XCTAssertEqual(try library.search.search(db, query: SearchQuery.parse("-has:tag")).count, 1)
        }
    }

    func testLockedThingsAreNotIndexed() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Sensitive Records")
            XCTAssertEqual(try library.search.search(db, query: SearchQuery.parse("Sensitive")).count, 1)
            try library.things.setLocked(db, id: thing.id, true)
            XCTAssertEqual(try library.search.search(db, query: SearchQuery.parse("Sensitive")).count, 0)
        }
    }
}

final class OplogTests: XCTestCase {

    func testHistoryCoversTheThingAndItsFields() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "History")
            let field = try library.fields.addField(db, thingID: thing.id, variantID: "plain", label: "Note")
            try library.fields.setText(db, fieldID: field.id, "hello")

            let history = try library.oplog.history(db, thingID: thing.id)
            XCTAssertGreaterThanOrEqual(history.count, 3)
            XCTAssertTrue(history.contains { $0.entityID == field.id })
        }
    }

    func testRestoreIsItselfHistory() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Original")
            try library.things.rename(db, id: thing.id, title: "Changed")

            let renameChange = try XCTUnwrap(
                library.oplog.changes(db, forEntity: thing.id).first { $0.operation == .update }
            )
            let before = try Change.fetchCount(db)
            try library.oplog.restore(db, changeID: renameChange.id)
            XCTAssertEqual(try library.things.find(db, id: thing.id)?.title, "Original")
            XCTAssertGreaterThan(try Change.fetchCount(db), before)
        }
    }

    func testUndoOfCreateRemovesTheRow() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Ephemeral")
            let creation = try XCTUnwrap(
                library.oplog.changes(db, forEntity: thing.id).first { $0.operation == .create }
            )
            try library.oplog.undo(db, changeID: creation.id)
            XCTAssertNil(try library.things.find(db, id: thing.id))
        }
    }

    func testUndoOfDeleteRestoresTheRow() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Comes back")
            try library.things.deleteForever(db, id: thing.id)
            let deletion = try XCTUnwrap(
                library.oplog.changes(db, forEntity: thing.id).first { $0.operation == .delete }
            )
            try library.oplog.undo(db, changeID: deletion.id)
            XCTAssertEqual(try library.things.find(db, id: thing.id)?.title, "Comes back")
        }
    }

    func testChangesAfterStampForSync() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let first = try library.things.create(db, title: "One")
            let marker = try XCTUnwrap(library.oplog.changes(db, forEntity: first.id).first?.stamp)
            _ = try library.things.create(db, title: "Two")
            let later = try library.oplog.changes(db, after: marker)
            XCTAssertFalse(later.isEmpty)
            XCTAssertTrue(later.allSatisfy { ($0.stamp.map { $0 > marker }) == true })
        }
    }
}

final class ConflictTests: XCTestCase {

    func testFieldLevelEditsDoNotConflict() throws {
        // Phone edits Notes, PC edits Password → two entities → both apply.
        let notesLocal = VersionVector(["phone": 2, "pc": 1])
        let notesRemote = VersionVector(["phone": 1, "pc": 1])
        XCTAssertEqual(ConflictDetector.resolution(local: notesLocal, remote: notesRemote), .keepLocal)

        let passwordLocal = VersionVector(["phone": 1, "pc": 1])
        let passwordRemote = VersionVector(["phone": 1, "pc": 2])
        XCTAssertEqual(ConflictDetector.resolution(local: passwordLocal, remote: passwordRemote), .applyRemote)
    }

    func testGenuineCollisionIsAConflict() throws {
        let local = VersionVector(["phone": 2, "pc": 1])
        let remote = VersionVector(["phone": 1, "pc": 2])
        XCTAssertEqual(ConflictDetector.resolution(local: local, remote: remote), .conflict)
    }

    func testRecordingAndResolving() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let thing = try library.things.create(db, title: "Contested")
            let mine = try XCTUnwrap(EntityColumns.snapshot(db, entityType: .thing, entityID: thing.id))
            var theirs = mine
            theirs["title"] = .string("Theirs")

            let conflictID = try library.conflicts.record(db, entityType: .thing, entityID: thing.id,
                                                          local: mine, remote: theirs)
            XCTAssertEqual(try library.conflicts.openConflicts(db).count, 1)

            try library.conflicts.resolve(db, conflictID: conflictID, choosing: .b, oplog: library.oplog)
            XCTAssertEqual(try library.things.find(db, id: thing.id)?.title, "Theirs")
            XCTAssertTrue(try library.conflicts.openConflicts(db).isEmpty)
        }
    }
}

final class CollectionTests: XCTestCase {

    func testManyToManyMembership() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let cloudflare = try library.things.create(db, title: "Cloudflare")
            let development = try library.collections.create(db, name: "Development")
            let nineteenEighty = try library.collections.create(db, name: "1980")
            try library.collections.add(db, thingID: cloudflare.id, to: development.id)
            try library.collections.add(db, thingID: cloudflare.id, to: nineteenEighty.id)

            XCTAssertEqual(try library.collections.collectionIDs(db, containing: cloudflare.id).count, 2)
            XCTAssertEqual(try library.collections.members(db, collectionID: development.id,
                                                           search: library.search).map { $0.id },
                           [cloudflare.id])
        }
    }

    func testSmartCollectionIsASavedSearch() throws {
        let library = try TestSupport.makeLibrary()
        try library.write { db in
            let pinned = try library.things.create(db, title: "Pinned One", isPinned: true)
            _ = try library.things.create(db, title: "Not Pinned")
            let smart = try library.collections.create(db, name: "Pinned", smartQuery: "is:pinned")
            XCTAssertTrue(smart.isSmart)
            let members = try library.collections.members(db, collectionID: smart.id, search: library.search)
            XCTAssertEqual(members.map { $0.id }, [pinned.id])
        }
    }
}
