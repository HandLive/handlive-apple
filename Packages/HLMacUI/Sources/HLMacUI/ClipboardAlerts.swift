import Foundation
import HLAppCore
import HLLocalization
import HLSMSNotifications
import UserNotifications

/// System notifications of the clipboard with a button (QC3 "Send Anyway", CLIP-01 API 6 "Send Again").
@MainActor
public protocol ClipboardAlerting: AnyObject {
    /// "Send Anyway" and "Send Again" chosen on the notification.
    var onSendAnyway: () -> Void { get set }
    var onSendAgain: () -> Void { get set }
    /// A response to an SMS notification (the center has one delegate, this one).
    var onSmsResponse: (SmsNotificationResponse) -> Void { get set }
    func post(_ alert: ClipboardAlert)
}

/// `UNUserNotificationCenter`: one notification per kind, replaced by the next one and removed after 120 s, when the
/// button stops working (CLIP-01 fields 9, 13).
@MainActor
public final class UserNotificationAlerts: NSObject, ClipboardAlerting, UNUserNotificationCenterDelegate {
    static let sensitiveCategory = "clip.sensitive"
    static let conflictCategory = "clip.conflict"
    static let sendAnywayAction = "clip.send_anyway"
    static let sendAgainAction = "clip.send_again"

    public var onSendAnyway: () -> Void = {}
    public var onSendAgain: () -> Void = {}
    public var onSmsResponse: (SmsNotificationResponse) -> Void = { _ in }

    /// Registers the categories and becomes the delegate; call at launch, before any notification arrives.
    public func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(SmsNotificationBuilder.categories().union([
            UNNotificationCategory(identifier: Self.sensitiveCategory,
                                   actions: [UNNotificationAction(identifier: Self.sendAnywayAction,
                                                                  title: L10n.Clipboard.sendAnyway)],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.conflictCategory,
                                   actions: [UNNotificationAction(identifier: Self.sendAgainAction,
                                                                  title: L10n.Clipboard.sendAgain)],
                                   intentIdentifiers: []),
        ]))
    }

    public func post(_ alert: ClipboardAlert) {
        let content = UNMutableNotificationContent()
        switch alert {
        case .sensitiveBlocked:
            content.title = L10n.Clipboard.sensitiveBlockedTitle
            content.body = L10n.Clipboard.sensitiveBlockedBody
            content.categoryIdentifier = Self.sensitiveCategory
        case .conflict(let deviceName):
            content.title = L10n.Clipboard.conflictTitle(deviceName: deviceName)
            content.body = L10n.Clipboard.conflictBody
            content.categoryIdentifier = Self.conflictCategory
        }
        let identifier = content.categoryIdentifier
        let center = UNUserNotificationCenter.current()
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        Task {
            try? await Task.sleep(for: .seconds(ClipboardConstants.staleAfter))
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let sms = SmsNotificationInfo(response.notification.request.content.userInfo)
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            switch action {
            case Self.sendAnywayAction: onSendAnyway()
            case Self.sendAgainAction: onSendAgain()
            case SmsNotificationKeys.replyAction:
                if let sms, let text { onSmsResponse(.reply(sms, text: text)) }
            case SmsNotificationKeys.markReadAction:
                if let sms { onSmsResponse(.markRead(sms)) }
            case UNNotificationDefaultActionIdentifier:
                if let sms { onSmsResponse(.open(sms)) }
            default: break
            }
        }
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
