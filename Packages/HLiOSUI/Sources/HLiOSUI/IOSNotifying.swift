import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLSMS
import HLSMSNotifications
import HLTransport
@preconcurrency import UserNotifications
#if os(iOS)
import UIKit
#endif

/// What the iPhone and iPad app does with notifications itself: the Notification Service Extension shows new SMS
/// while the app is closed (CONN-04); the app removes those read here or on the phone (SMS-05 API 2), keeps the icon
/// badge, and says when a quick reply could not go out (SMS-04 field 11). Tests use a stub.
@MainActor
public protocol IOSNotifying: AnyObject {
    /// Notifications of one conversation: up to `upToTs`, or all of them.
    func remove(pairId: String, threadId: Int64, upToTs: Int64?)
    /// Every SMS notification (unpairing).
    func removeAllSms()
    /// The generic notifications shown while the device was locked, once SMS-01 brought their messages in.
    func removeGeneric()
    /// Every delivered and pending notification ("Delete All HandLive Data", SET-02 API 7).
    func removeEverything()
    /// The app icon badge: the number of unread conversations (02-ios-ipados.md, Pairing and notifications).
    func setBadge(_ count: Int)
    /// "Not sent yet. Open HandLive to try again." after a quick reply without `ack` (SMS-04 API 5 logic 3).
    func postNotSentYet(pairId: String, threadId: Int64)
    /// A new SMS that came over the session during the background grace: the notification the extension shows for its
    /// push (SMS-02 API 4, CONN-02 E3).
    func postSms(_ incoming: SmsIncoming, showPreview: Bool)
    /// The notification permission as it is now (SET-03 field 7, CONN-04 field 1).
    func permission() async -> NotificationPermission
    /// SET-03 step 7: `requestAuthorization([.alert, .sound, .badge])` once; afterwards only the state is read.
    func requestPermission() async -> NotificationPermission
    /// SET-03 field 8: Time Sensitive notifications turned off let a Focus silence incoming calls.
    func timeSensitive() async -> TimeSensitiveSetting
}

#if os(iOS)
/// `UNUserNotificationCenter` on iPhone and iPad.
@MainActor
public final class UserNotificationsIOS: IOSNotifying {
    public init() {}

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

    public func removeAllSms() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.filter {
                SmsNotificationInfo($0.request.content.userInfo) != nil
                    || $0.request.content.categoryIdentifier.hasPrefix("HL_SMS")
            }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    public func removeGeneric() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = SmsNotificationFilter.genericIdentifiers(in: delivered.map {
                DeliveredNotification(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo)
            })
            if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        }
    }

    public func removeEverything() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        center.setBadgeCount(0)
    }

    public func permission() async -> NotificationPermission {
        await NotificationPermission.current()
    }

    public func requestPermission() async -> NotificationPermission {
        await NotificationPermission.request()
    }

    public func timeSensitive() async -> TimeSensitiveSetting {
        await TimeSensitiveSetting.current()
    }

    public func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    public func postSms(_ incoming: SmsIncoming, showPreview: Bool) {
        let unlocked = UIApplication.shared.isProtectedDataAvailable
        let new = SmsNewData(message: incoming.message, thread: incoming.thread)
        let content = GraceNotificationContent.sms(new, pairId: incoming.pairId, simLabel: incoming.simLabel,
                                                   showPreview: showPreview, unlocked: unlocked)
        let shown = unlocked ? SmsNotificationBuilder.communication(content, new: new, showPreview: showPreview) : content
        let key = incoming.message.messageKey
        let request = UNNotificationRequest(
            identifier: SmsNotificationKeys.identifier(pairId: incoming.pairId, messageKey: key), content: shown, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error == nil { BenchLog.event("sms_notified", ["msg": key]) }
        }
    }

    public func postNotSentYet(pairId: String, threadId: Int64) {
        let content = UNMutableNotificationContent()
        content.body = L10n.Sms.quickReplyNotSent
        content.threadIdentifier = SmsNotificationKeys.threadIdentifier(pairId: pairId, threadId: threadId)
        content.userInfo = [SmsNotificationKeys.pairId: pairId, SmsNotificationKeys.threadId: NSNumber(value: threadId)]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "sms-not-sent:\(pairId):\(threadId)", content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
#endif
