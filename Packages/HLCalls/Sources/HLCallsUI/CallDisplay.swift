import Foundation
import HLAppCore
import HLCallNotifications
import HLCalls
import HLLocalization
import HLProtocol

/// Texts of the call screens, formatted with the system formatters for the displayed locale (0.12.3).
public enum CallDisplay {
    /// CALL-04 field 4: "2:05 PM" today, the date when older ("Sep 12", with the year when not this year).
    public static func listTime(_ ts: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// CALL-04 field 5: "2 minutes, 5 seconds"; `nil` for a call of 0 seconds (hidden).
    public static func duration(_ seconds: Int32) -> String? {
        guard seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        return formatter.string(from: TimeInterval(seconds))
    }

    /// The in-call timer and "Call ended · mm:ss" (CALL-03 fields 2–3): "02:15", "1:02:15" past an hour.
    public static func timer(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: TimeInterval(max(0, seconds))) ?? "00:00"
    }

    /// CALL-04 field 2: the name, the number in national format, or "No Caller ID".
    public static func title(_ record: CallLogRecord) -> String {
        CallNames.title(caller(record))
    }

    static func caller(_ record: CallLogRecord) -> CallerIdentity {
        CallerIdentity(entry: CallLogEntryData(entryId: record.entryId, number: record.number,
                                               displayName: record.displayName, type: record.type, ts: record.ts,
                                               durationS: record.durationS, subId: record.subId))
    }

    /// CALL-04 field 3: the symbol of each call type.
    public static func symbol(_ type: CallLogType) -> String {
        switch type {
        case .incoming: "phone.arrow.down.left"
        case .outgoing: "phone.arrow.up.right"
        case .missed: "phone.arrow.down.left"
        case .rejected: "phone.down"
        case .blocked: "nosign"
        case .voicemail: "recordingtape"
        case .unrecognized: "phone"
        }
    }

    /// The line under the name: the SIM label when the phone has two SIMs, and the duration (fields 5–6).
    public static func detail(_ record: CallLogRecord, simLabel: String?) -> String? {
        let parts = [simLabel, duration(record.durationS)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for a row: the caller, "Missed call" for a missed one, the time and the details.
    public static func accessibilityLabel(_ record: CallLogRecord, simLabel: String?, now: Date = Date()) -> String {
        var parts = [title(record)]
        if record.type == .missed { parts.append(L10n.Call.missedCall) }
        parts.append(listTime(record.ts, now: now))
        if let detail = detail(record, simLabel: simLabel) { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}
