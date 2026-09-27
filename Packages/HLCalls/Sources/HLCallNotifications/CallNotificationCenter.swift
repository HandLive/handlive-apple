import Foundation
import HLAppCore
import HLSMSNotifications
import HLTransport
@preconcurrency import UserNotifications

/// What the Mac and the iPhone/iPad app do alike with `UNUserNotificationCenter` for calls: post a missed call and
/// remove the delivered notifications a `CallNotificationFilter` rule picks.
public enum CallNotificationCenter {
    /// CALL-04 API 4: one notification per missed call, logged as `call_missed_notified` (HLBENCH/1).
    public static func postMissed(_ missed: MissedCall, canMessage: Bool) {
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

    /// Removes the delivered notifications `pick` chooses; it runs off the main thread with plain values.
    public static func removeDelivered(_ pick: @escaping @Sendable ([DeliveredNotification]) -> [String]) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = pick(delivered.map(item))
            if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        }
    }

    /// A delivered notification as the filters read it.
    public static func item(_ notification: UNNotification) -> DeliveredNotification {
        DeliveredNotification(identifier: notification.request.identifier,
                              userInfo: notification.request.content.userInfo,
                              category: notification.request.content.categoryIdentifier)
    }
}
