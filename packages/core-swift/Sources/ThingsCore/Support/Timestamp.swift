import Foundation

/// ISO-8601 UTC with milliseconds — `2026-08-09T21:14:03.412Z`.
///
/// Implemented with integer arithmetic rather than `DateFormatter` on purpose:
///   * `DateFormatter` is locale- and calendar-sensitive, and the Screenshot Tour needs
///     byte-identical output on every run.
///   * `ISO8601DateFormatter` gained `.withFractionalSeconds` late and rounds oddly.
///   * The TypeScript core produces exactly this shape from `Date#toISOString()`.
public enum Timestamp {

    public static let millisecondsPerDay: Int64 = 86_400_000

    /// Days-from-civil (Howard Hinnant's algorithm), valid for the whole proleptic
    /// Gregorian calendar. No table lookups, no leap-year special cases at call sites.
    public static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                             // [0, 399]
        let mp = (month + 9) % 12                                           // [0, 11]
        let doy = (153 * mp + 2) / 5 + day - 1                              // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                     // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    public static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097                                         // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365    // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)                   // [0, 365]
        let mp = (5 * doy + 2) / 153                                        // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                                // [1, 31]
        let m = mp + (mp < 10 ? 3 : -9)                                     // [1, 12]
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    public static func string(millisecondsSinceEpoch millis: Int64) -> String {
        var days = millis / millisecondsPerDay
        var remainder = millis % millisecondsPerDay
        if remainder < 0 {
            remainder += millisecondsPerDay
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        let hour = remainder / 3_600_000
        let minute = (remainder / 60_000) % 60
        let second = (remainder / 1000) % 60
        let milli = remainder % 1000

        var out = ""
        out.reserveCapacity(24)
        out += pad(year, width: 4)
        out += "-"
        out += pad(month, width: 2)
        out += "-"
        out += pad(day, width: 2)
        out += "T"
        out += pad(hour, width: 2)
        out += ":"
        out += pad(minute, width: 2)
        out += ":"
        out += pad(second, width: 2)
        out += "."
        out += pad(milli, width: 3)
        out += "Z"
        return out
    }

    public static func string(_ date: Date) -> String {
        string(millisecondsSinceEpoch: milliseconds(date))
    }

    public static func milliseconds(_ date: Date) -> Int64 {
        // `rounded()` rather than truncation so 0.4109999 ms does not become 410 on one
        // platform and 411 on another.
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    public static func date(millisecondsSinceEpoch millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000.0)
    }

    /// Parses the exact shape produced by `string(millisecondsSinceEpoch:)`, and is
    /// tolerant of a missing fractional part and of `+00:00` in place of `Z`.
    public static func milliseconds(fromISO8601 text: String) -> Int64? {
        let scalars = Array(text.utf8)
        func digits(_ range: Range<Int>) -> Int64? {
            guard range.upperBound <= scalars.count else { return nil }
            var value: Int64 = 0
            for index in range {
                let byte = scalars[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int64(byte - 0x30)
            }
            return value
        }
        guard scalars.count >= 19,
              let year = digits(0..<4), scalars[4] == 0x2D,
              let month = digits(5..<7), scalars[7] == 0x2D,
              let day = digits(8..<10), scalars[10] == 0x54 || scalars[10] == 0x20,
              let hour = digits(11..<13), scalars[13] == 0x3A,
              let minute = digits(14..<16), scalars[16] == 0x3A,
              let second = digits(17..<19)
        else { return nil }

        var milli: Int64 = 0
        if scalars.count > 19, scalars[19] == 0x2E {
            var index = 20
            var place = 100
            while index < scalars.count, scalars[index] >= 0x30, scalars[index] <= 0x39 {
                if place >= 1 {
                    milli += Int64(scalars[index] - 0x30) * Int64(place)
                    place /= 10
                }
                index += 1
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        return days * millisecondsPerDay
            + hour * 3_600_000
            + minute * 60_000
            + second * 1000
            + milli
    }

    public static func date(fromISO8601 text: String) -> Date? {
        guard let millis = milliseconds(fromISO8601: text) else { return nil }
        return date(millisecondsSinceEpoch: millis)
    }

    static func pad(_ value: Int64, width: Int) -> String {
        var digits = String(value < 0 ? -value : value)
        while digits.count < width { digits = "0" + digits }
        return value < 0 ? "-" + digits : digits
    }
}
