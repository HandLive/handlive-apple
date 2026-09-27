import Foundation
import HLProtocol
import HLSMSNotifications

/// Which delivered call notifications go away. Matched by `userInfo`, because the ones the extension shows carry
/// identifiers the system chose. A generic call push (shown while the device was locked, or when the extension could
/// not open it) has only the relay's `p` and `hl`: the `call_event` type of its envelope and the APNs `loc-key` are
/// plain; what the call is needs `decode`, which the app runs with the pair's `K_push` while it is unlocked.
public enum CallNotificationFilter {
    /// The APNs `loc-key` of a generic missed-call push (CONN-04 API 4).
    static let missedLocKey = "push.call_missed"

    /// The incoming-call notifications of `callId`: its `state` is no longer `ringing` (CALL-01 step 12).
    public static func incomingIdentifiers(in delivered: [DeliveredNotification], callId: String,
                                           decode: ([AnyHashable: Any]) -> CallStateData? = { _ in nil }) -> [String] {
        delivered.compactMap { item in
            if case .incoming(_, let id, _)? = CallNotificationInfo(item.userInfo) {
                return id == callId ? item.identifier : nil
            }
            guard genericPush(item.userInfo) != nil, decode(item.userInfo)?.callId == callId else { return nil }
            return item.identifier
        }
    }

    /// Every incoming-call notification whose call started more than `CallNotificationBuilder.latePushMs` ago, when
    /// the app enters the foreground (CALL-01 API 6 logic 4). A generic one is judged by the ringing state `decode`
    /// finds in its push, or by its envelope's `ts` (sent while the call rang) when the push no longer opens.
    public static func staleIncomingIdentifiers(in delivered: [DeliveredNotification], nowMs: Int64,
                                                decode: ([AnyHashable: Any]) -> CallStateData?) -> [String] {
        delivered.compactMap { item in
            let startedAt: Int64?
            if case .incoming(_, _, let started)? = CallNotificationInfo(item.userInfo) {
                startedAt = started
            } else if let push = genericPush(item.userInfo), !push.missed {
                startedAt = decode(item.userInfo).map(\.startedAt) ?? push.envelopeTs
            } else {
                startedAt = nil
            }
            guard let startedAt, nowMs - startedAt > CallNotificationBuilder.latePushMs else { return nil }
            return item.identifier
        }
    }

    /// Missed-call notifications of the pair: one entry or call when given; all of them otherwise, the generic ones
    /// included (CALL-04 step 12).
    public static func missedIdentifiers(in delivered: [DeliveredNotification], pairId: String, entryId: Int64? = nil,
                                         callId: String? = nil) -> [String] {
        delivered.compactMap { item in
            guard case .missed(let pair, let entry, let call, _, _)? = CallNotificationInfo(item.userInfo) else {
                guard entryId == nil, callId == nil, let push = genericPush(item.userInfo), push.pairId == pairId,
                      push.missed else { return nil }
                return item.identifier
            }
            guard pair == pairId else { return nil }
            if entryId == nil, callId == nil { return item.identifier }
            let matches = (entryId != nil && entry == entryId) || (callId != nil && call == callId)
            return matches ? item.identifier : nil
        }
    }

    /// Every call notification, generic ones included (unpairing, calls turned off).
    public static func callIdentifiers(in delivered: [DeliveredNotification]) -> [String] {
        delivered.filter { CallNotificationInfo($0.userInfo) != nil || genericPush($0.userInfo) != nil }
            .map(\.identifier)
    }

    /// What the plain part of a generic call push says.
    struct GenericPush {
        let pairId: String
        /// The relay sent it as a missed call (its `loc-key`).
        let missed: Bool
        /// When the phone sealed it: while the call rang, for an incoming call.
        let envelopeTs: Int64
    }

    /// A generic call push; `nil` for anything else.
    static func genericPush(_ userInfo: [AnyHashable: Any]) -> GenericPush? {
        guard CallNotificationInfo(userInfo) == nil, let fields = PushAlertFields(userInfo: userInfo),
              fields.envelope.type == .callEvent else { return nil }
        let alert = (userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any]
        return GenericPush(pairId: fields.pairId, missed: alert?["loc-key"] as? String == missedLocKey,
                           envelopeTs: fields.envelope.ts)
    }
}
