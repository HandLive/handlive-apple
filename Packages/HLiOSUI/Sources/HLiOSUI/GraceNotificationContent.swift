import Foundation
import HLCallNotifications
import HLLocalization
import HLProtocol
import HLSMSNotifications
@preconcurrency import UserNotifications

/// What the app posts for an SMS or a ringing call that came over the session during the background grace (CONN-02
/// E3): exactly what the extension shows for the push. Unlocked, the content the extension decrypts, the SMS text only
/// with `sms.preview` on (SMS-02 field 2); locked, the push's generic text — no title, no number, no content, no button
/// (SMS-02 E4, CALL-01 E6, CONN-04 API 4 logic 2).
enum GraceNotificationContent {
    /// Unlocked, the caller adds the communication form (sender, avatar, Focus) as for the extension.
    static func sms(_ new: SmsNewData, pairId: String, simLabel: String?, showPreview: Bool,
                    unlocked: Bool) -> UNMutableNotificationContent {
        guard unlocked else {
            let content = UNMutableNotificationContent()
            content.body = L10n.Push.smsNew
            content.threadIdentifier = "sms" // a locked iPhone keeps every SMS push in one group
            content.sound = .default
            return content
        }
        return SmsNotificationBuilder.content(for: new, pairId: pairId, simLabel: simLabel, showPreview: showPreview)
    }

    /// The ringing call, time-sensitive with "Decline" when the phone allows it; locked, "Incoming call on your phone"
    /// without a button. Both carry the call's `userInfo`, so the app removes them once the call stops ringing.
    static func incomingCall(_ state: CallStateData, pairId: String, unlocked: Bool,
                             nowMs: Int64) -> UNMutableNotificationContent {
        let content = CallNotificationBuilder.incoming(state, pairId: pairId, platform: .mobile, level: .timeSensitive,
                                                       nowMs: nowMs).makeContent()
        content.sound = .default // the APNs alert always carries `sound: "default"` (CONN-04 API 4)
        guard !unlocked else { return content }
        content.title = ""
        content.body = L10n.Push.callIncoming
        content.categoryIdentifier = ""
        return content
    }
}
