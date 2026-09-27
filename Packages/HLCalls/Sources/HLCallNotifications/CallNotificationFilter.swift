import Foundation
import HLProtocol
import HLSMSNotifications

/// Which delivered call notifications go away. Matched by `userInfo`, because the ones the extension shows carry
/// identifiers the system chose.
public enum CallNotificationFilter {
    /// The incoming-call notifications of `callId`: its `state` is no longer `ringing` (CALL-01 step 12).
    public static func incomingIdentifiers(in delivered: [DeliveredNotification], callId: String) -> [String] {
        delivered.compactMap { item in
            guard case .incoming(_, let id, _)? = CallNotificationInfo(item.userInfo), id == callId else { return nil }
            return item.identifier
        }
    }

    /// Every incoming-call notification whose call started more than `CallNotificationBuilder.latePushMs` ago, when
    /// the app enters the foreground (CALL-01 API 6 logic 4). A generic one shown while the device was locked is
    /// judged by the ringing state `decode` finds in its push, when there is one.
    public static func staleIncomingIdentifiers(in delivered: [DeliveredNotification], nowMs: Int64,
                                                decode: ([AnyHashable: Any]) -> CallStateData?) -> [String] {
        delivered.compactMap { item in
            let startedAt: Int64?
            if case .incoming(_, _, let started)? = CallNotificationInfo(item.userInfo) {
                startedAt = started
            } else if item.userInfo["hl"] != nil {
                startedAt = decode(item.userInfo).map(\.startedAt)
            } else {
                startedAt = nil
            }
            guard let startedAt, nowMs - startedAt > CallNotificationBuilder.latePushMs else { return nil }
            return item.identifier
        }
    }

    /// Missed-call notifications of the pair: one entry or call when given, all of them otherwise (CALL-04 step 12).
    public static func missedIdentifiers(in delivered: [DeliveredNotification], pairId: String, entryId: Int64? = nil,
                                         callId: String? = nil) -> [String] {
        delivered.compactMap { item in
            guard case .missed(let pair, let entry, let call, _, _)? = CallNotificationInfo(item.userInfo),
                  pair == pairId else { return nil }
            if entryId == nil, callId == nil { return item.identifier }
            let matches = (entryId != nil && entry == entryId) || (callId != nil && call == callId)
            return matches ? item.identifier : nil
        }
    }
}
