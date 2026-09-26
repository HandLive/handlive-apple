import Foundation
import HLProtocol
import HLSMS
import HLSMSNotifications
import HLTransport
@preconcurrency import UserNotifications

/// SMS notifications of the Mac (SMS-02 API 4, SMS-05 API 2); tests use a stub.
@MainActor
public protocol SmsNotifying: AnyObject {
    func post(_ incoming: SmsIncoming, showPreview: Bool)
    /// Notifications of one conversation: up to `upToTs`, or all of them.
    func remove(pairId: String, threadId: Int64, upToTs: Int64?)
    /// Every SMS notification (unpairing, deleting all data).
    func removeAll()
}

/// What the user did with an SMS notification (SMS-04 API 5, SMS-05 A2, SMS-03 step 1).
public enum SmsNotificationResponse: Equatable, Sendable {
    case reply(SmsNotificationInfo, text: String)
    case markRead(SmsNotificationInfo)
    case open(SmsNotificationInfo)
}

/// `UNUserNotificationCenter` as the SMS notifier; the delegate that receives the responses is `UserNotificationAlerts`.
@MainActor
public final class UserNotificationSms: SmsNotifying {
    public init() {}

    public func post(_ incoming: SmsIncoming, showPreview: Bool) {
        let new = SmsNewData(message: incoming.message, thread: incoming.thread)
        let request = SmsNotificationBuilder.request(for: new, pairId: incoming.pairId, simLabel: incoming.simLabel,
                                                     showPreview: showPreview)
        let key = incoming.message.messageKey
        UNUserNotificationCenter.current().add(request) { error in
            if error == nil { BenchLog.event("sms_notified", ["msg": key]) }
        }
    }

    public func remove(pairId: String, threadId: Int64, upToTs: Int64?) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let items = delivered.map {
                DeliveredNotification(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo,
                                      category: $0.request.content.categoryIdentifier)
            }
            let identifiers = SmsNotificationFilter.identifiers(in: items, pairId: pairId, threadId: threadId,
                                                                upToTs: upToTs)
            if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        }
    }

    public func removeAll() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.filter { SmsNotificationInfo($0.request.content.userInfo) != nil }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}
