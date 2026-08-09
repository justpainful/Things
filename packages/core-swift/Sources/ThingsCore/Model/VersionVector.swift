import Foundation

/// How two version vectors relate.
public enum VersionOrdering: String, Sendable, Equatable {
    /// Identical histories.
    case equal
    /// The left vector has seen everything the right one has, and more.
    case dominates
    /// The right vector has seen everything the left one has, and more.
    case dominated
    /// Neither has seen the other. This is the only case that is a conflict.
    case concurrent
}

/// `{deviceId: counter}`. Timestamps cannot tell "later" from "concurrent"; this can.
public struct VersionVector: Equatable, Hashable, Sendable {

    public private(set) var counters: [String: Int]

    public init(_ counters: [String: Int] = [:]) {
        self.counters = counters.filter { $0.value > 0 }
    }

    public static let empty = VersionVector()

    public subscript(deviceID: String) -> Int {
        counters[deviceID] ?? 0
    }

    public var isEmpty: Bool { counters.isEmpty }

    public var deviceIDs: [String] { counters.keys.sorted() }

    @discardableResult
    public mutating func increment(_ deviceID: String, by amount: Int = 1) -> Int {
        let value = (counters[deviceID] ?? 0) + amount
        counters[deviceID] = value
        return value
    }

    public func incrementing(_ deviceID: String, by amount: Int = 1) -> VersionVector {
        var copy = self
        copy.increment(deviceID, by: amount)
        return copy
    }

    public func merged(with other: VersionVector) -> VersionVector {
        var merged = counters
        for (device, counter) in other.counters {
            merged[device] = max(merged[device] ?? 0, counter)
        }
        return VersionVector(merged)
    }

    /// The whole point of the type.
    public func compare(to other: VersionVector) -> VersionOrdering {
        var selfAhead = false
        var otherAhead = false
        var devices = Set(counters.keys)
        devices.formUnion(other.counters.keys)
        for device in devices {
            let mine = self[device]
            let theirs = other[device]
            if mine > theirs { selfAhead = true }
            if theirs > mine { otherAhead = true }
            if selfAhead && otherAhead { return .concurrent }
        }
        if selfAhead { return .dominates }
        if otherAhead { return .dominated }
        return .equal
    }

    public func dominates(_ other: VersionVector) -> Bool {
        let ordering = compare(to: other)
        return ordering == .dominates || ordering == .equal
    }

    public func isConcurrent(with other: VersionVector) -> Bool {
        compare(to: other) == .concurrent
    }

    // MARK: - Wire form

    /// Canonical: sorted keys, no whitespace. Stored in `version_vector TEXT`.
    public var json: String {
        var members: [String: JSONValue] = [:]
        for (device, counter) in counters {
            members[device] = .number(counter)
        }
        return JSONValue.object(members).canonicalJSON
    }

    /// Never throws: a malformed vector degrades to empty, which is treated as
    /// "dominated by everything" and therefore heals on the next sync.
    public static func parse(_ text: String?) -> VersionVector {
        guard let text, !text.isEmpty else { return .empty }
        guard let value = try? JSONValue.parse(text),
              let members = value.objectValue
        else { return .empty }
        var counters: [String: Int] = [:]
        for (device, member) in members {
            if let counter = member.intValue, counter > 0 {
                counters[device] = counter
            }
        }
        return VersionVector(counters)
    }
}
