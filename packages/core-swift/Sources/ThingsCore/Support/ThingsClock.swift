import Foundation
import Security

/// The one source of "now" and of randomness in the whole core.
///
/// Everything that would otherwise call `Date()` or `UUID()` goes through this, because
/// the Screenshot Tour pixel-diffs its output and a drifting "2 hours ago" makes the
/// entire visual-review loop useless.
public protocol ThingsClock: AnyObject, Sendable {
    /// Milliseconds since the Unix epoch, UTC.
    func nowMilliseconds() -> Int64
    /// Cryptographically random in production; deterministic under test.
    func randomBytes(_ count: Int) -> [UInt8]
}

public extension ThingsClock {
    func now() -> Date { Timestamp.date(millisecondsSinceEpoch: nowMilliseconds()) }
    func nowISO8601() -> String { Timestamp.string(millisecondsSinceEpoch: nowMilliseconds()) }
}

/// Production clock: real time, real randomness.
public final class SystemClock: ThingsClock, @unchecked Sendable {

    public static let shared = SystemClock()

    public init() {}

    public func nowMilliseconds() -> Int64 {
        Timestamp.milliseconds(Date())
    }

    /// `SecRandomCopyBytes`, not `UInt8.random`.
    ///
    /// This is the source of the DEK, of every per-object key, and of every nonce.
    /// `SystemRandomNumberGenerator` is documented as cryptographically secure "whenever
    /// possible", and "whenever possible" is not a sentence you want under a password
    /// store. `SecRandomCopyBytes` has no such qualifier.
    public func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            // Never silently return predictable bytes: a weak key is worse than a crash,
            // and a failure here means the platform's CSPRNG is unavailable.
            preconditionFailure("SecRandomCopyBytes failed with OSStatus \(status)")
        }
        return bytes
    }
}

/// Deterministic clock for seed data, the Screenshot Tour, and conformance tests.
///
/// Time advances by a fixed step per call so that ids stay strictly ordered without any
/// dependence on how fast the machine runs. Randomness is a plain xorshift — this is a
/// *test* clock and must never be used to generate a real key.
public final class FixedClock: ThingsClock, @unchecked Sendable {

    private let lock = NSLock()
    private var currentMillis: Int64
    private let stepMillis: Int64
    private var state: UInt64

    public init(startISO8601: String = "2026-08-09T09:00:00.000Z",
                stepMilliseconds: Int64 = 1,
                seed: UInt64 = 0x5EED_1980_C0FF_EE01) {
        self.currentMillis = Timestamp.milliseconds(fromISO8601: startISO8601) ?? 0
        self.stepMillis = stepMilliseconds
        self.state = seed == 0 ? 1 : seed
    }

    public func nowMilliseconds() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let value = currentMillis
        currentMillis += stepMillis
        return value
    }

    /// Moves the clock without consuming a tick — used by seed data to place a Thing
    /// "three days ago" relative to the frozen present.
    public func advance(milliseconds: Int64) {
        lock.lock()
        currentMillis += milliseconds
        lock.unlock()
    }

    public func set(iso8601: String) {
        lock.lock()
        currentMillis = Timestamp.milliseconds(fromISO8601: iso8601) ?? currentMillis
        lock.unlock()
    }

    /// The current instant without advancing — for stamping several rows with one time.
    public func peekMilliseconds() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return currentMillis
    }

    public func randomBytes(_ count: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return bytes
    }
}
