import Foundation
import XCTest
@testable import ThingsCore

enum TestSupport {

    /// Walks up from this source file to the repository root — the directory that contains
    /// both `spec/` and `packages/`. Works under `swift test` and under `xcodebuild test`,
    /// because `#filePath` is baked in at compile time and CI compiles from the checkout.
    static var repositoryRoot: URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let spec = url.appendingPathComponent("spec", isDirectory: true)
            let packages = url.appendingPathComponent("packages", isDirectory: true)
            if FileManager.default.fileExists(atPath: spec.path),
               FileManager.default.fileExists(atPath: packages.path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    static var specDirectory: URL? {
        repositoryRoot?.appendingPathComponent("spec", isDirectory: true)
    }

    static var vectorsDirectory: URL? {
        guard let directory = specDirectory?.appendingPathComponent("vectors", isDirectory: true) else { return nil }
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    static func vectorFiles() -> [URL] {
        guard let directory = vectorsDirectory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.path < $1.path }
    }

    static func registry() throws -> FieldKindRegistry {
        try FieldKindRegistry.loadBundled()
    }

    /// An in-memory, unencrypted library. Crypto has its own tests; this one is for SQL.
    static func makeLibrary(clock: ThingsClock = FixedClock()) throws -> Library {
        let database = try ThingsDatabase.open(
            ThingsDatabase.Configuration(
                path: nil,
                key: nil,
                deviceID: "00000000-0000-7000-8000-0000000000aa",
                deviceName: "Test Device",
                platform: "ios"
            ),
            clock: clock
        )
        let objects = FileManager.default.temporaryDirectory
            .appendingPathComponent("things-tests-\(UUID().uuidString)", isDirectory: true)
        return Library(database: database,
                       dek: KeyHierarchy.generateDEK(clock: clock),
                       objectsDirectory: objects)
    }
}
