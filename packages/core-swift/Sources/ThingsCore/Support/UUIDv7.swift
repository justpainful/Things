import Foundation

/// UUIDv7 — 48 bits of Unix-epoch milliseconds, then version/variant bits, then random.
///
/// RFC 9562 §5.7 layout:
///
///     0                   1                   2                   3
///     |            unix_ts_ms (48 bits)               |ver| rand_a |
///     |var|                    rand_b (62 bits)                    |
///
/// Time-sortable ids mean creation order survives without a second index, and they sort
/// identically in Swift and JavaScript because both compare the canonical lowercase
/// hyphenated string.
public enum UUIDv7 {

    /// Builds an id from an explicit timestamp and 10 bytes of randomness.
    /// Split out from `generate` so conformance vectors can pin exact output.
    public static func make(millisecondsSinceEpoch millis: Int64, random: [UInt8]) -> String {
        precondition(random.count >= 10, "UUIDv7 needs 10 random bytes")
        var bytes = [UInt8](repeating: 0, count: 16)

        let unsigned = UInt64(bitPattern: millis) & 0x0000_FFFF_FFFF_FFFF
        bytes[0] = UInt8truncating(unsigned >> 40)
        bytes[1] = UInt8truncating(unsigned >> 32)
        bytes[2] = UInt8truncating(unsigned >> 24)
        bytes[3] = UInt8truncating(unsigned >> 16)
        bytes[4] = UInt8truncating(unsigned >> 8)
        bytes[5] = UInt8truncating(unsigned)

        bytes[6] = (random[0] & 0x0F) | 0x70          // version 7
        bytes[7] = random[1]
        bytes[8] = (random[2] & 0x3F) | 0x80          // RFC 4122 variant
        bytes[9] = random[3]
        bytes[10] = random[4]
        bytes[11] = random[5]
        bytes[12] = random[6]
        bytes[13] = random[7]
        bytes[14] = random[8]
        bytes[15] = random[9]

        return format(bytes)
    }

    public static func generate(clock: ThingsClock = SystemClock.shared) -> String {
        make(millisecondsSinceEpoch: clock.nowMilliseconds(), random: clock.randomBytes(10))
    }

    /// The embedded creation instant, or nil if this is not a v7 id.
    public static func millisecondsSinceEpoch(of id: String) -> Int64? {
        guard let bytes = rawBytes(of: id), bytes.count == 16 else { return nil }
        guard bytes[6] >> 4 == 0x7 else { return nil }
        var value: UInt64 = 0
        for index in 0..<6 {
            value = (value << 8) | UInt64(bytes[index])
        }
        return Int64(bitPattern: value)
    }

    public static func creationDate(of id: String) -> Date? {
        guard let millis = millisecondsSinceEpoch(of: id) else { return nil }
        return Timestamp.date(millisecondsSinceEpoch: millis)
    }

    public static func isValid(_ id: String) -> Bool {
        guard let bytes = rawBytes(of: id), bytes.count == 16 else { return false }
        return bytes[6] >> 4 == 0x7 && bytes[8] >> 6 == 0b10
    }

    /// Accepts the canonical hyphenated form only. Anything else is a bug elsewhere and
    /// we would rather see it than silently normalise it.
    public static func rawBytes(of id: String) -> [UInt8]? {
        let characters = Array(id.utf8)
        guard characters.count == 36 else { return nil }
        guard characters[8] == 0x2D, characters[13] == 0x2D,
              characters[18] == 0x2D, characters[23] == 0x2D else { return nil }
        var stripped = [UInt8]()
        stripped.reserveCapacity(32)
        for (index, byte) in characters.enumerated() where !(index == 8 || index == 13 || index == 18 || index == 23) {
            stripped.append(byte)
        }
        return Hex.decode(String(decoding: stripped, as: UTF8.self))
    }

    static func format(_ bytes: [UInt8]) -> String {
        let hex = Hex.encode(bytes)
        let characters = Array(hex)
        var out = ""
        out.reserveCapacity(36)
        out += String(characters[0..<8])
        out += "-"
        out += String(characters[8..<12])
        out += "-"
        out += String(characters[12..<16])
        out += "-"
        out += String(characters[16..<20])
        out += "-"
        out += String(characters[20..<32])
        return out
    }

    private static func UInt8truncating(_ value: UInt64) -> UInt8 {
        UInt8(truncatingIfNeeded: value)
    }
}
