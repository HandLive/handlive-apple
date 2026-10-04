import Foundation

/// "5 minutes ago" in the display language (SMS-01 field 4, CALL-04 field 11), never "in 0 seconds": the numeric
/// `RelativeDateTimeFormatter` prints any gap under a second, past ones included, as "in 0 seconds" ("sau 0 giây
/// nữa"), which is what a sync that just finished showed. A moment less than a minute ago, or in the future, reads
/// "now", as on Android (`RelativeTime`; design system › Writing, "Numbers, dates, times").
public enum HLRelativeTime {
    public static func past(milliseconds: Int64, now: Date = Date(), locale: Locale = .current) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        guard now.timeIntervalSince(then) >= 60 else {
            formatter.dateTimeStyle = .named
            return formatter.localizedString(from: DateComponents(second: 0))
        }
        return formatter.localizedString(for: then, relativeTo: now)
    }
}
