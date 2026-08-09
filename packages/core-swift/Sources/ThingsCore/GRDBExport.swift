/// ThingsCore re-exports GRDB.
///
/// The public repository API takes a `Database` — every read and write runs inside a GRDB
/// transaction, and hiding that would mean either wrapping several hundred call sites or
/// giving up transactional grouping, which is exactly what makes "write the row, bump the
/// vector, append the oplog entry, reindex" atomic.
///
/// Re-exporting means the app writes `import ThingsCore` and gets `Database`,
/// `FetchableRecord.fetchAll` and friends without declaring GRDB a second time in
/// `project.yml` — and a second declaration of the same package URL is a class of
/// resolution failure nobody here can debug quickly.
///
/// Live queries are still bridged to plain `AsyncThrowingStream` in `Observation.swift`, so
/// no SwiftUI view ever handles a GRDB observation type directly.
@_exported import GRDB
