import Foundation
import HLDesignSystem
import HLLocalization
import HLProtocol
import HLSMS
import HLSMSNotifications

/// Texts of the Messages screens, formatted with the system formatters for the displayed locale (0.12.3).
public enum SmsDisplay {
    /// SMS-03 field 4: "2:05 PM" today, "Yesterday", "Sep 12" (with the year when it is not this year).
    public static func listTime(_ ts: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return dayMarker(ts, now: now, calendar: calendar) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Day markers in a conversation: "Today", "Yesterday", "Sep 12" (SMS-03 field 7).
    public static func dayMarker(_ ts: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.doesRelativeDateFormatting = true
            return formatter.string(from: date)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Time under a bubble.
    public static func bubbleTime(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts) / 1000).formatted(date: .omitted, time: .shortened)
    }

    /// SMS-04 field 8: the reason of a failed message by error code.
    public static func failureReason(_ code: ErrorCode?) -> String {
        switch code {
        case .smsNoService?: L10n.Error.smsNoService
        case .smsRadioOff?: L10n.Error.smsRadioOff
        case .smsLimitExceeded?: L10n.Error.smsLimitExceeded
        case .smsInvalidAddress?: L10n.Error.smsInvalidAddress
        case .smsSimUnavailable?: L10n.Error.smsSimUnavailable
        case .notConnected?: L10n.Error.smsNotConnected
        default: L10n.Error.smsGenericFailure
        }
    }

    /// The status shown under a message written here.
    public static func bubbleStatus(_ state: SmsSendState?, error: ErrorCode?) -> MessageBubble.Status? {
        switch state {
        case .pending?: .pending
        case .sending?: .sending
        case .sent?: .sent
        case .delivered?: .delivered
        case .failed?: .failed(reason: failureReason(error))
        case nil: nil
        }
    }

    /// The status word VoiceOver reads (the `sms.status_*` texts).
    public static func statusText(_ status: MessageBubble.Status?) -> String {
        switch status {
        case .pending?: L10n.Sms.statusPending
        case .sending?: L10n.Sms.statusSending
        case .sent?: L10n.Sms.statusSent
        case .delivered?: L10n.Sms.statusDelivered
        case .failed(let reason)?: L10n.Sms.statusFailedReason(reason: reason)
        case nil: ""
        }
    }

    /// SMS-04 field 3: "0/160" while empty, then "{used}/{limit} · {parts}", the limit being what the current number of
    /// parts holds.
    public static func counter(for text: String) -> String {
        let estimate = SmsPartCounter.estimate(text)
        guard estimate.parts > 0 else { return L10n.Sms.charCount(used: "0", limit: "\(estimate.capacity)") }
        return L10n.Sms.charCounter(used: "\(estimate.units)", limit: "\(estimate.capacity)",
                                    parts: L10n.Sms.partCount(count: estimate.parts))
    }

    /// Time (and SIM on dual-SIM phones) under a message.
    public static func bubbleFootnote(_ ts: Int64, simLabel: String?) -> String {
        [bubbleTime(ts), simLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// VoiceOver label of a bubble (SMS-03 special requirements): "{sender}, {time}" for a received message — the
    /// sender's number in a group conversation — and "You, {time}, {status}" for a sent one; the text is the value.
    public static func bubbleAccessibility(_ message: SmsMessage, thread: SmsThread?,
                                           status: MessageBubble.Status?) -> String {
        guard message.isIncoming else {
            return L10n.A11y.smsBubbleSent(time: bubbleTime(message.ts), status: statusText(status ?? .sent))
        }
        let sender = thread.map { SmsNames.title(displayName: $0.isGroup ? nil : $0.displayName,
                                                 addresses: $0.isGroup ? [message.address] : $0.addresses) }
            ?? PhoneNumberDisplay.format(message.address)
        return L10n.A11y.smsBubbleReceived(sender: sender, time: bubbleTime(message.ts))
    }

    /// VoiceOver label of a placeholder bubble (a message written here that the phone has not echoed yet).
    public static func placeholderAccessibility(_ entry: SmsOutboxEntry, status: MessageBubble.Status?) -> String {
        L10n.A11y.smsBubbleSent(time: bubbleTime(entry.createdAt), status: statusText(status ?? .pending))
    }

    /// The row of a conversation.
    public static func row(_ thread: SmsThread, lastSendFailed: Bool = false) -> ThreadRow.Model {
        let avatar: ThreadRow.Avatar = if thread.isGroup {
            .group
        } else if let initials = InitialsAvatar.initials(of: thread.displayName) {
            .initials(initials)
        } else {
            .unknownNumber
        }
        return ThreadRow.Model(title: SmsNames.title(displayName: thread.displayName, addresses: thread.addresses),
                               snippet: thread.snippet ?? "", time: listTime(thread.lastTs), avatar: avatar,
                               isUnread: thread.isUnread, unreadCount: Int(thread.unreadCount),
                               lastSendFailed: lastSendFailed)
    }
}
