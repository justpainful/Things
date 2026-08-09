import Foundation
import GRDB

/// One indexed Thing.
///
/// **Secret values are never in here.** A `secret` field contributes its *label* and a
/// marker token, which is what implements "show Things that contain a Password without
/// revealing the password". That is a security property, not a UI preference.
///
/// Locked Things contribute nothing at all while locked.
public struct SearchDocument: Sendable, Equatable {
    public var thingID: String
    public var title: String = ""
    public var labels: String = ""
    public var values: String = ""
    public var notes: String = ""
    public var tags: String = ""
    public var urls: String = ""
    public var paths: String = ""
    public var filenames: String = ""
    public var collections: String = ""
    public var markers: String = ""

    public init(thingID: String) {
        self.thingID = thingID
    }

    /// In `SchemaSQL.searchColumns` order, which both index implementations rely on.
    public var orderedValues: [String] {
        [thingID, title, labels, values, notes, tags, urls, paths, filenames, collections, markers]
    }
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var thingID: String
    public var title: String
    public var snippet: String?
    public var rank: Double

    public var id: String { thingID }

    public init(thingID: String, title: String, snippet: String? = nil, rank: Double = 0) {
        self.thingID = thingID
        self.title = title
        self.snippet = snippet
        self.rank = rank
    }
}

/// Behind a protocol on purpose.
///
/// It is unverified whether FTS5 is compiled into the SQLCipher binary inside Zetetic's
/// GRDB fork. If it is not, `LikeSearchIndex` is swapped in at `ThingsDatabase.open` and no
/// call site changes.
public protocol SearchIndex: Sendable {
    var name: String { get }
    var tableName: String { get }

    func upsert(_ db: Database, document: SearchDocument) throws
    func remove(_ db: Database, thingID: String) throws
    func removeAll(_ db: Database) throws
    /// Free-text portion only. Structured filters are applied by `SearchService` in SQL
    /// against the materialised tables, because FTS tokenisation cannot be trusted to keep
    /// `has:password` in one piece.
    func matchingThingIDs(_ db: Database, query: SearchQuery, limit: Int) throws -> [String]
    func snippet(_ db: Database, thingID: String, query: SearchQuery) throws -> String?
}

public extension SearchIndex {
    func snippet(_ db: Database, thingID: String, query: SearchQuery) throws -> String? { nil }
}
