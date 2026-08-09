import Foundation

/// Lowercase hex, hand written. `String(format:)` is locale-sensitive in ways that have
/// bitten people, and this runs on the hash path.
public enum Hex {

    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    public static func encode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func encode(_ data: Data) -> String {
        encode([UInt8](data))
    }

    public static func decode(_ string: String) -> [UInt8]? {
        let scalars = Array(string.utf8)
        guard scalars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = nibble(scalars[index]), let low = nibble(scalars[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    public static func decodeData(_ string: String) -> Data? {
        guard let bytes = decode(string) else { return nil }
        return Data(bytes)
    }

    private static func nibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: return ascii - 0x30            // 0-9
        case 0x61...0x66: return ascii - 0x61 + 10       // a-f
        case 0x41...0x46: return ascii - 0x41 + 10       // A-F
        default: return nil
        }
    }
}
