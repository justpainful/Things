import Foundation
import ThingsCore

/// Human dates, computed against an *injected* present.
///
/// Never `Date()`. "2 hours ago" drifting between two CI runs would flag every screen as
/// changed, and a pixel diff that cries wolf is ignored within a week.
enum RelativeTime {

    /// How much room the caller has.
    ///
    /// `.short` exists for AccessibilityXXL, where "2 hours ago" truncates to "2 hours a…"
    /// in a list row. Shortening the *words* is the right answer; shrinking the *type* would
    /// defeat the accessibility setting the user chose. Still plain English — "2 hr", not
    /// "2h" and certainly not a duration format nobody speaks.
    enum Style {
        case full
        case short
    }

    static func string(fromISO8601 text: String?,
                       nowMilliseconds: Int64,
                       style: Style = .full) -> String {
        guard let text, let then = Timestamp.milliseconds(fromISO8601: text) else { return "—" }
        let delta = nowMilliseconds - then

        let minute: Int64 = 60_000
        let hour = 60 * minute
        let day = 24 * hour

        let isShort = style == .short

        if delta < minute { return isShort ? "Now" : "Just now" }
        if delta < hour {
            let minutes = delta / minute
            if isShort { return "\(minutes) min" }
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        if delta < day {
            let hours = delta / hour
            if isShort { return "\(hours) hr" }
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        if delta < 2 * day { return "Yesterday" }
        if delta < 7 * day {
            let days = delta / day
            return isShort ? "\(days) days" : "\(days) days ago"
        }
        return absoluteDay(text)
    }

    /// `9 Aug 2026`. Hand-formatted rather than `DateFormatter`, so the tour's pinned
    /// locale is genuinely pinned and not merely requested.
    static func absoluteDay(_ iso8601: String) -> String {
        guard let millis = Timestamp.milliseconds(fromISO8601: iso8601) else { return "—" }
        let days = millis / Timestamp.millisecondsPerDay
        let civil = Timestamp.civilFromDays(days)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let monthIndex = Int(civil.month) - 1
        let monthName = months.indices.contains(monthIndex) ? months[monthIndex] : "?"
        return "\(civil.day) \(monthName) \(civil.year)"
    }

    static func dayHeading(_ iso8601: String, nowMilliseconds: Int64) -> String {
        guard let millis = Timestamp.milliseconds(fromISO8601: iso8601) else { return "Earlier" }
        let today = nowMilliseconds / Timestamp.millisecondsPerDay
        let day = millis / Timestamp.millisecondsPerDay
        switch today - day {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "This Week"
        default: return absoluteDay(iso8601)
        }
    }
}

enum ByteSize {

    static func string(_ bytes: Int64) -> String {
        let units: [(String, Int64)] = [("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)]
        for (suffix, divisor) in units where bytes >= divisor {
            let value = Double(bytes) / Double(divisor)
            return String(format: "%.1f %@", value, suffix)
        }
        return "\(bytes) bytes"
    }
}

extension String {

    /// Word count without allocating a full array of substrings for a 20 000-word note.
    var approximateWordCount: Int {
        var count = 0
        var inWord = false
        for character in self {
            if character.isWhitespace || character.isNewline {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}
