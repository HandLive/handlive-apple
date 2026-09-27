import Foundation
import HLProtocol
import UserNotifications

/// Identifiers of call notifications (CALL-01 API 6–7, CALL-04 API 4): categories, actions, thread and request
/// identifiers, and the `userInfo` keys the actions read back.
public enum CallNotificationKeys {
    /// iPhone and iPad: "Decline" only (CALL-01 API 6), when `controls.reject` allows it.
    public static let incomingCategory = "HL_CALL_INCOMING"
    /// Mac: "Answer" and "Decline" (CALL-01 API 7), when `controls` allow both.
    public static let incomingMacCategory = "HL_CALL_INCOMING_MAC"
    /// Missed call with "Message" (CALL-04 API 4).
    public static let missedCategory = "HL_CALL_MISSED"
    public static let answerAction = "HL_CALL_ANSWER"
    public static let rejectAction = "HL_CALL_REJECT"
    public static let messageAction = "HL_CALL_SMS"

    /// Every incoming call, and a missed call the relay pushed, share the thread `calls`.
    public static let threadIdentifier = "calls"

    static let pairId = "pair_id"
    static let callId = "call_id"
    static let startedAt = "started_at"
    static let entryId = "entry_id"
    static let number = "number"
    static let subId = "sub_id"

    /// `calls:<pair_id>`: the missed calls this app posts itself.
    public static func missedThreadIdentifier(pairId: String) -> String {
        "calls:\(pairId)"
    }

    /// `call-missed:<pair_id>:<entry_id>`; flow A, without an entry: `call-missed:<pair_id>:<call_id>`.
    public static func missedIdentifier(pairId: String, entryId: Int64?, callId: String?) -> String {
        "call-missed:\(pairId):\(entryId.map(String.init) ?? callId ?? "")"
    }
}

/// The `userInfo` of a call notification, written and read back (CALL-01 API 6–7, CALL-04 API 4). Absent values are
/// left out of the notification's `userInfo`, which only takes property-list values.
public enum CallNotificationInfo: Equatable, Sendable {
    /// `{pair_id, call_id, started_at}`: the Decline and Answer actions (CALL-02 B2).
    case incoming(pairId: String, callId: String, startedAt: Int64)
    /// `{pair_id, entry_id, call_id, number, sub_id}`: "Message" and marking the entry seen.
    case missed(pairId: String, entryId: Int64?, callId: String?, number: String?, subId: Int32?)

    public var pairId: String {
        switch self {
        case .incoming(let pairId, _, _), .missed(let pairId, _, _, _, _): pairId
        }
    }

    public var userInfo: [AnyHashable: Any] {
        typealias Key = CallNotificationKeys
        switch self {
        case .incoming(let pairId, let callId, let startedAt):
            return [Key.pairId: pairId, Key.callId: callId, Key.startedAt: NSNumber(value: startedAt)]
        case .missed(let pairId, let entryId, let callId, let number, let subId):
            var info: [AnyHashable: Any] = [Key.pairId: pairId]
            if let entryId { info[Key.entryId] = NSNumber(value: entryId) }
            if let callId { info[Key.callId] = callId }
            if let number { info[Key.number] = number }
            if let subId { info[Key.subId] = NSNumber(value: subId) }
            return info
        }
    }

    /// The JSON form of `call-notification.schema.json` (every key present, `null` when absent).
    public var json: [String: Any] {
        switch self {
        case .incoming(let pairId, let callId, let startedAt):
            return [CallNotificationKeys.pairId: pairId, CallNotificationKeys.callId: callId,
                    CallNotificationKeys.startedAt: startedAt]
        case .missed(let pairId, let entryId, let callId, let number, let subId):
            return [CallNotificationKeys.pairId: pairId, CallNotificationKeys.entryId: entryId.map { $0 as Any } ?? NSNull(),
                    CallNotificationKeys.callId: callId ?? NSNull(), CallNotificationKeys.number: number ?? NSNull(),
                    CallNotificationKeys.subId: subId.map { $0 as Any } ?? NSNull()]
        }
    }

    /// Reads a call notification's `userInfo`; `nil` for any other notification.
    public init?(_ userInfo: [AnyHashable: Any]) {
        typealias Key = CallNotificationKeys
        guard let pairId = userInfo[Key.pairId] as? String, HLUUID.isCanonical(pairId) else { return nil }
        let callId = userInfo[Key.callId] as? String
        if let startedAt = (userInfo[Key.startedAt] as? NSNumber)?.int64Value, let callId {
            self = .incoming(pairId: pairId, callId: callId, startedAt: startedAt)
            return
        }
        let entryId = (userInfo[Key.entryId] as? NSNumber)?.int64Value
        guard entryId != nil || callId != nil else { return nil }
        self = .missed(pairId: pairId, entryId: entryId, callId: callId, number: userInfo[Key.number] as? String,
                       subId: (userInfo[Key.subId] as? NSNumber)?.int32Value)
    }
}

/// What the user did with a call notification.
public enum CallNotificationResponse: Equatable, Sendable {
    /// "Answer" on the Mac (CALL-01 API 7).
    case answer(pairId: String, callId: String)
    /// "Decline" (Mac API 7, iPhone/iPad `HL_CALL_REJECT`, CALL-02 B1).
    case reject(pairId: String, callId: String, startedAt: Int64)
    /// A click on the incoming-call notification: the panel comes to the front, the iPhone app opens.
    case openIncoming(pairId: String, callId: String)
    /// "Message" with the text typed in the notification (CALL-04 API 4).
    case message(pairId: String, entryId: Int64?, callId: String?, number: String, subId: Int32?, text: String)
    /// A click on a missed-call notification: the call list opens and the entry is seen (CALL-04 step 12).
    case openMissed(pairId: String, entryId: Int64?, callId: String?)

    public init?(actionIdentifier: String, userInfo: [AnyHashable: Any], userText: String?) {
        switch CallNotificationInfo(userInfo) {
        case .incoming(let pairId, let callId, let startedAt)?:
            guard let response = Self.incoming(actionIdentifier, pairId: pairId, callId: callId, startedAt: startedAt)
            else { return nil }
            self = response
        case .missed(let pairId, let entryId, let callId, let number, let subId)?:
            switch actionIdentifier {
            case CallNotificationKeys.messageAction:
                guard let number, let userText else { return nil }
                self = .message(pairId: pairId, entryId: entryId, callId: callId, number: number, subId: subId,
                                text: userText)
            case UNNotificationDefaultActionIdentifier:
                self = .openMissed(pairId: pairId, entryId: entryId, callId: callId)
            default: return nil
            }
        case nil:
            return nil
        }
    }

    private static func incoming(_ action: String, pairId: String, callId: String,
                                 startedAt: Int64) -> CallNotificationResponse? {
        switch action {
        case CallNotificationKeys.answerAction: .answer(pairId: pairId, callId: callId)
        case CallNotificationKeys.rejectAction: .reject(pairId: pairId, callId: callId, startedAt: startedAt)
        case UNNotificationDefaultActionIdentifier: .openIncoming(pairId: pairId, callId: callId)
        default: nil
        }
    }
}
