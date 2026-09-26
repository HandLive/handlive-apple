import Foundation
import HLProtocol

/// Identifiers of SMS notifications (SMS-02 API 4): categories, actions, request and thread identifiers, and the
/// `userInfo` keys that quick reply (SMS-04 API 5) and removal (SMS-05 API 2) read back.
public enum SmsNotificationKeys {
    /// One-recipient conversations: "Reply" and "Mark as Read".
    public static let category = "HL_SMS"
    /// Group conversations: no "Reply" (SMS-04 E9).
    public static let groupCategory = "HL_SMS_GROUP"
    public static let replyAction = "HL_SMS_REPLY"
    public static let markReadAction = "HL_SMS_MARK_READ"

    public static let pairId = "pair_id"
    public static let threadId = "thread_id"
    public static let messageKey = "message_key"
    public static let ts = "ts"
    public static let address = "address"
    public static let subId = "sub_id"

    /// `sms:<pair_id>:<message_key>`.
    public static func identifier(pairId: String, messageKey: String) -> String {
        "sms:\(pairId):\(messageKey)"
    }

    /// `sms:<pair_id>:<thread_id>`: groups the notifications of one conversation.
    public static func threadIdentifier(pairId: String, threadId: Int64) -> String {
        "sms:\(pairId):\(threadId)"
    }

    /// `{pair_id, thread_id, message_key, ts, address, sub_id}` of SMS-02 API 4.
    public static func userInfo(pairId pair: String, message: SmsMessageData) -> [String: Any] {
        var info: [String: Any] = [Self.pairId: pair, Self.threadId: message.threadId, Self.messageKey: message.messageKey,
                                   Self.ts: message.ts, Self.address: message.address]
        if let sub = message.subId { info[Self.subId] = sub }
        return info
    }
}

/// The `userInfo` of an SMS notification read back (quick reply, removal).
public struct SmsNotificationInfo: Equatable, Sendable {
    public let pairId: String
    public let threadId: Int64
    public let messageKey: String?
    public let ts: Int64?
    public let address: String?
    public let subId: Int32?

    public init?(_ userInfo: [AnyHashable: Any]) {
        guard let pairId = userInfo[SmsNotificationKeys.pairId] as? String,
              let threadId = (userInfo[SmsNotificationKeys.threadId] as? NSNumber)?.int64Value
        else { return nil }
        self.pairId = pairId
        self.threadId = threadId
        messageKey = userInfo[SmsNotificationKeys.messageKey] as? String
        ts = (userInfo[SmsNotificationKeys.ts] as? NSNumber)?.int64Value
        address = userInfo[SmsNotificationKeys.address] as? String
        subId = (userInfo[SmsNotificationKeys.subId] as? NSNumber)?.int32Value
    }
}

/// A notification shown in Notification Center, as the removal rules look at it.
public struct DeliveredNotification: @unchecked Sendable {
    public let identifier: String
    public let userInfo: [AnyHashable: Any]
    public let category: String

    public init(identifier: String, userInfo: [AnyHashable: Any], category: String = "") {
        self.identifier = identifier
        self.userInfo = userInfo
        self.category = category
    }
}

/// Which delivered notifications go away (SMS-05 API 2): matched by `userInfo`, because the ones the extension shows
/// carry identifiers chosen by the system.
public enum SmsNotificationFilter {
    /// A conversation read on the phone up to `upToTs`, or opened here (`upToTs` `nil`: all of them).
    public static func identifiers(in delivered: [DeliveredNotification], pairId: String, threadId: Int64,
                                   upToTs: Int64?) -> [String] {
        delivered.compactMap { item in
            guard let info = SmsNotificationInfo(item.userInfo), info.pairId == pairId, info.threadId == threadId
            else { return nil }
            if let upToTs, let ts = info.ts, ts > upToTs { return nil }
            return item.identifier
        }
    }

    /// The generic notifications shown while the device was locked (the relay's `p` and `hl` but none of our keys),
    /// removed once SMS-01 has brought their messages into the app (logic 2).
    public static func genericIdentifiers(in delivered: [DeliveredNotification]) -> [String] {
        delivered.filter { SmsNotificationInfo($0.userInfo) == nil && $0.userInfo["p"] != nil }.map(\.identifier)
    }
}
