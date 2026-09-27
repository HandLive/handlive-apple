import Foundation
import HLAppCore
import HLCallNotifications
import HLProtocol
import HLSMSNotifications
import HLTransport
@preconcurrency import UserNotifications

/// Call notifications of the Mac (CALL-01 API 7, CALL-04 API 4); tests use a stub.
@MainActor
public protocol CallNotifying: AnyObject {
    /// The incoming call's communication notification (identifier = `call_id`), posted again to update it.
    func postIncoming(_ state: CallStateData, pairId: String, level: CallNotificationContent.Level)
    /// The call is no longer ringing (step 12), or its alert changed.
    func removeIncoming(callId: String)
    func postMissed(_ missed: MissedCall, canMessage: Bool)
    /// A pair's missed-call notifications: one entry's, or all of them (CALL-04 step 12).
    func removeMissed(pairId: String, entryId: Int64?)
    /// Every call notification (unpairing, calls turned off).
    func removeAllCalls()
}

/// `UNUserNotificationCenter` as the call notifier; the delegate that receives the responses is
/// `UserNotificationAlerts`.
@MainActor
public final class UserNotificationCalls: CallNotifying {
    /// What each incoming notification shows now, so an unchanged state is not posted again (no second banner).
    private var posted: [String: CallNotificationContent] = [:]

    public init() {}

    public func postIncoming(_ state: CallStateData, pairId: String, level: CallNotificationContent.Level) {
        let content = CallNotificationBuilder.incoming(state, pairId: pairId, platform: .mac, level: level,
                                                       nowMs: HLUUID.currentTimeMs())
        guard posted[state.callId] != content else { return }
        posted[state.callId] = content
        let shown = CallNotificationBuilder.communication(content.makeContent(), state: state)
        let callId = state.callId
        let benchLevel = level == .timeSensitive ? "time_sensitive" : "passive"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: callId, content: shown, trigger: nil)) {
            if $0 == nil { BenchLog.event("call_notified", ["call": callId, "level": benchLevel]) }
        }
    }

    public func removeIncoming(callId: String) {
        guard posted.removeValue(forKey: callId) != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [callId])
        center.removePendingNotificationRequests(withIdentifiers: [callId])
    }

    public func postMissed(_ missed: MissedCall, canMessage: Bool) {
        let content = CallNotificationBuilder.missed(missed, canMessage: canMessage)
        let request = UNNotificationRequest(identifier: content.identifier ?? UUID().uuidString,
                                            content: content.makeContent(), trigger: nil)
        var bench = [("call", missed.callId ?? "none"), ("source", missed.entryId == nil ? "state" : "log_new")]
        if let entry = missed.entryId { bench.append(("entry", String(entry))) }
        let fields = bench
        UNUserNotificationCenter.current().add(request) {
            if $0 == nil { BenchLog.event("call_missed_notified", fields: fields) }
        }
    }

    public func removeMissed(pairId: String, entryId: Int64?) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = CallNotificationFilter.missedIdentifiers(in: delivered.map(Self.item), pairId: pairId,
                                                                       entryId: entryId)
            if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        }
    }

    public func removeAllCalls() {
        posted.removeAll()
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.filter { CallNotificationInfo($0.request.content.userInfo) != nil }
                .map(\.request.identifier)
            if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        }
    }

    nonisolated static func item(_ notification: UNNotification) -> DeliveredNotification {
        DeliveredNotification(identifier: notification.request.identifier,
                              userInfo: notification.request.content.userInfo,
                              category: notification.request.content.categoryIdentifier)
    }
}
