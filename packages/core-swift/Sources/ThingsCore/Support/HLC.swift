import Foundation

/// Hybrid logical clock.
///
/// Wire form — fixed width so plain string comparison is the correct ordering, which is
/// what lets `ORDER BY hlc` work in SQLite with no custom collation:
///
///     2026-08-09T21:14:03.412Z-0000-a1b2c3d4
///     └─ physical, readable in the History UI ─┘ └counter┘ └device id┘
///
/// Physical time stays readable, but causality comes from the counter, so a phone with a
/// skewed clock cannot silently win an argument with the PC.
public struct HLC: Hashable, Comparable, Sendable, CustomStringConvertible {

    public let millis: Int64
    public let counter: Int
    public let deviceID: String

    public init(millis: Int64, counter: Int, deviceID: String) {
        self.millis = millis
        self.counter = counter
        self.deviceID = deviceID
    }

    public var description: String {
        "\(Timestamp.string(millisecondsSinceEpoch: millis))-\(HLC.counterString(counter))-\(deviceID)"
    }

    public var date: Date { Timestamp.date(millisecondsSinceEpoch: millis) }

    public static func counterString(_ counter: Int) -> String {
        let clamped = max(0, min(counter, 0xFFFF))
        var hex = String(clamped, radix: 16, uppercase: false)
        while hex.count < 4 { hex = "0" + hex }
        return hex
    }

    /// Parses the wire form. Device ids may contain hyphens (they are UUIDs), so the
    /// split is positional: the timestamp is always 24 characters and the counter 4.
    public static func parse(_ text: String) -> HLC? {
        let characters = Array(text)
        guard characters.count > 24 + 1 + 4 + 1 else { return nil }
        let timestampText = String(characters[0..<24])
        guard characters[24] == "-" else { return nil }
        let counterText = String(characters[25..<29])
        guard characters[29] == "-" else { return nil }
        let deviceText = String(characters[30...])
        guard let millis = Timestamp.milliseconds(fromISO8601: timestampText),
              let counter = Int(counterText, radix: 16),
              !deviceText.isEmpty
        else { return nil }
        return HLC(millis: millis, counter: counter, deviceID: deviceText)
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        if lhs.millis != rhs.millis { return lhs.millis < rhs.millis }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID < rhs.deviceID
    }
}

/// Issues monotonically increasing stamps, and folds in stamps received from a peer.
public final class HLCGenerator: @unchecked Sendable {

    private let lock = NSLock()
    private let clock: ThingsClock
    private let deviceID: String
    private var lastMillis: Int64
    private var counter: Int

    /// Refuses to accept a peer stamp more than this far in the future — otherwise one
    /// device with a badly wrong clock permanently poisons the ordering.
    public static let maximumDriftMilliseconds: Int64 = 60 * 60 * 1000

    public init(deviceID: String, clock: ThingsClock = SystemClock.shared, resumingFrom last: HLC? = nil) {
        self.deviceID = deviceID
        self.clock = clock
        self.lastMillis = last?.millis ?? 0
        self.counter = last?.counter ?? 0
    }

    /// A stamp for a locally-originated change.
    public func next() -> HLC {
        lock.lock()
        defer { lock.unlock() }
        let physical = clock.nowMilliseconds()
        if physical > lastMillis {
            lastMillis = physical
            counter = 0
        } else {
            counter += 1
        }
        return HLC(millis: lastMillis, counter: counter, deviceID: deviceID)
    }

    /// A stamp for a change received from `remote`, per the HLC receive rule.
    public func receive(_ remote: HLC) -> HLC {
        lock.lock()
        defer { lock.unlock() }
        let physical = clock.nowMilliseconds()
        let remoteMillis = min(remote.millis, physical + HLCGenerator.maximumDriftMilliseconds)
        let newMillis = max(physical, max(lastMillis, remoteMillis))

        if newMillis == lastMillis && newMillis == remoteMillis {
            counter = max(counter, remote.counter) + 1
        } else if newMillis == lastMillis {
            counter += 1
        } else if newMillis == remoteMillis {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        lastMillis = newMillis
        return HLC(millis: lastMillis, counter: counter, deviceID: deviceID)
    }

    public var current: HLC {
        lock.lock()
        defer { lock.unlock() }
        return HLC(millis: lastMillis, counter: counter, deviceID: deviceID)
    }
}
