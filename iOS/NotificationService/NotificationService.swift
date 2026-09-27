import Foundation
import HLAppCore
import HLCallNotifications
import HLCrypto
import HLProtocol
import HLSMSNotifications
import HLTransport
import UserNotifications

/// I-NSE (CONN-04 step 9b, SMS-02 API 4, CALL-01 API 6, CALL-04 API 4): opens the `hl` envelope with `K_push` of the
/// pair named by `p`, while the iPhone is unlocked — the `PRK` sits in the Keychain group shared with the app, readable
/// only when unlocked (C3). A new SMS becomes a communication notification with the sender, the text (unless previews
/// are off) and the conversation's thread; a ringing call a time-sensitive `INStartCallIntent` notification with
/// "Decline" (`HL_CALL_INCOMING`), or "Incoming call at <time>" without a button when the push is over 60 s late (E7);
/// a missed call its title and time, with "Message" only when the app's copy of the phone's SMS send capability says
/// so. Locked, another pair, older than 24 h, already shown or anything unexpected: the generic text the APNs
/// `loc-key` names stays (E5–E7, E9). No database, no network: well under the 30 MB limit.
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
        let prk: (String) -> Data? = { pairId in try? secrets.load(account: SecretAccount.pairKey(pairId: pairId)) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: Self.appGroup) ?? .standard)
        if let call = CallPushDecoder.decode(userInfo: request.content.userInfo, nowMs: now, prk: prk) {
            guard Self.deduplicator()?.firstSighting(of: call.envelopeId, nowMs: now) ?? true else {
                return deliver(request.content)
            }
            return deliver(Self.callContent(call, request: request, settings: settings, nowMs: now))
        }
        guard let decoded = SmsPushDecoder.decode(userInfo: request.content.userInfo, nowMs: now, prk: prk),
              Self.deduplicator()?.firstSighting(of: decoded.envelopeId, nowMs: now) ?? true
        else { return deliver(request.content) }
        let content = SmsNotificationBuilder.content(for: decoded.new, pairId: decoded.pairId, simLabel: nil,
                                                     showPreview: settings.smsPreview)
        let shown = SmsNotificationBuilder.communication(content, new: decoded.new, showPreview: settings.smsPreview)
        Self.configureBench() // the extension has no device id; msg links the lines
        BenchLog.event("sms_push_shown", ["msg": decoded.new.message.messageKey])
        deliver(shown)
    }

    /// CALL-01 API 6 and CALL-04 API 4 on the push's own content, which keeps its level, sound and `p`/`hl`.
    private static func callContent(_ call: CallPushDecoder.Decoded, request: UNNotificationRequest,
                                    settings: AppSettings, nowMs: Int64) -> UNNotificationContent {
        configureBench() // the extension has no device id; call links the lines
        switch call.content {
        case .incoming(let state):
            let content = CallNotificationBuilder.incoming(state, pairId: call.pairId, platform: .mobile,
                                                           level: .timeSensitive, nowMs: nowMs)
            let late = content.categoryIdentifier == nil
            BenchLog.event("call_push_shown", ["call": state.callId, "reason": "call_incoming",
                                               "late": late ? "true" : "false"])
            let base = content.makeContent(base: request.content)
            return late ? base : CallNotificationBuilder.communication(base, state: state)
        case .missed(let missed):
            let canMessage = settings.peerCanSend(pairId: call.pairId) == true
            BenchLog.event("call_push_shown", ["call": missed.callId ?? "none", "reason": "call_missed", "late": "false"])
            return CallNotificationBuilder.missed(missed, canMessage: canMessage, pushed: true)
                .makeContent(base: request.content)
        }
    }

    /// The extension's bench lines: role `ios` under its own subsystem.
    private static func configureBench() {
        BenchLog.configure(deviceId: "00000000", role: .ios, subsystem: "app.handlive.ios.nse")
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
