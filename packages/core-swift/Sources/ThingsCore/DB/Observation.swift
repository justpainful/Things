import Foundation
import GRDB

/// Bridges GRDB's `AsyncValueObservation` to a plain `AsyncThrowingStream`.
///
/// Deliberate: the app target never imports GRDB. Everything it sees is a Foundation type
/// or a ThingsCore type, so a GRDB API change is one package to fix rather than forty
/// SwiftUI files. (GRDBQuery would be the other way to do this; it has been dormant since
/// 2025 and is not adopted here.)
///
/// No GRDB generic type is named in a signature below, on purpose — `ValueReducers.Fetch`
/// and friends are exactly the kind of spelling that changes between majors, and nobody on
/// this project can find that out in less than a CI round trip.
public enum LiveQuery {

    public static func stream<Value: Sendable, Reader: DatabaseReader>(
        in reader: Reader,
        fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking(fetch)
                    for try await value in observation.values(in: reader) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
