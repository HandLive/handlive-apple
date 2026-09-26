import Foundation
import HLAppCore
import HLCrypto
import HLProtocol
import HLSMSNotifications
import HLTransport
import UserNotifications

/// I-NSE (CONN-04 step 9b, SMS-02 API 4): opens the `hl` envelope with `K_push` of the pair named by `p`, while the
/// iPhone is unlocked — the `PRK` sits in the Keychain group shared with the app, readable only when unlocked (C3) —
/// and turns the notification into a communication notification with the sender, the text (unless previews are off)
/// and the conversation's thread. Locked, another pair, older than 24 h, already shown or anything unexpected: the
/// generic text the APNs `loc-key` names stays (E5, E7). No database, no network: well under the 30 MB limit.
final class NotificationService: UNNotificationServiceExtension {
    private static let appGroup = "group.app.handlive"
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var generic: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        generic = request.content
        let now = HLUUID.currentTimeMs()
        let secrets = KeychainSecretStore(accessGroup: Self.appGroup)
        guard let decoded = SmsPushDecoder.decode(userInfo: request.content.userInfo, nowMs: now, prk: { pairId in
            try? secrets.load(account: SecretAccount.pairKey(pairId: pairId))
        }), Self.deduplicator()?.firstSighting(of: decoded.envelopeId, nowMs: now) ?? true
        else { return deliver(request.content) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: Self.appGroup) ?? .standard)
        let content = SmsNotificationBuilder.content(for: decoded.new, pairId: decoded.pairId, simLabel: nil,
                                                     showPreview: settings.smsPreview)
        let shown = SmsNotificationBuilder.communication(content, new: decoded.new, showPreview: settings.smsPreview)
        BenchLog.configure(deviceId: "00000000", role: .ios) // the extension has no device id; msg links the lines
        BenchLog.event("sms_push_shown", ["msg": decoded.new.message.messageKey])
        deliver(shown)
    }

    /// iOS is about to give up: the generic text stays.
    override func serviceExtensionTimeWillExpire() {
        if let generic { deliver(generic) }
    }

    private func deliver(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }

    /// The envelope ids already shown, in the App Group container (E7).
    private static func deduplicator() -> PushDeduplicator? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { PushDeduplicator(fileURL: $0.appendingPathComponent("push-ids.json")) }
    }
}
