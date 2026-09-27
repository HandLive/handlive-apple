import Foundation
import HLAppCore
import HLCallNotifications
import HLCalls
import HLCrypto
import HLLocalization
import HLProtocol
import HLSMS
import HLTransport
@preconcurrency import UserNotifications

extension IOSAppModel {
    /// A "Decline" from a notification older than this is not sent: the call has certainly ended (CALL-02 API 6
    /// logic 2).
    static let callDeclineMaxAgeMs: Int64 = 90_000

    /// Calls on this device (CALL-01…04): the call log shares the encrypted database with SMS; the extension's copy of
    /// the phone's SMS send capability follows the capability.
    func startCalls() {
        calls.smsCanSend = { [weak self] in self?.smsEngine?.canSend ?? false }
        calls.capabilityChanged = { [weak self] in self?.scheduleCapabilityUpdate() }
        calls.pushReader = { [weak self] in self?.callPushReader() ?? { _ in nil } }
        calls.start(database: messages?.store.database)
        calls.setPair(pairedDevice)
        storePeerCanSend(pairedDevice?.peerCapability)
    }

    /// Opens the active pair's call pushes with its `K_push`, read now while the app runs unlocked (C3).
    func callPushReader(nowMs: Int64 = HLUUID.currentTimeMs()) -> CallPushReader {
        guard let pairId = pairedDevice?.pairId,
              let prk = try? secrets.load(account: SecretAccount.pairKey(pairId: pairId)) else { return { _ in nil } }
        return { userInfo in
            let decoded = CallPushDecoder.decode(userInfo: userInfo, nowMs: nowMs) { $0 == pairId ? prk : nil }
            guard case .incoming(let state)? = decoded?.content else { return nil }
            return state
        }
    }

    /// `sms.peer_can_send` (0.9.5): the extension offers "Message" on a pushed missed call only when this copy says
    /// the phone can send SMS — `features.sms.can_send`, with SMS on at both ends (CALL-04 API 4 logic 2).
    func storePeerCanSend(_ capability: CapabilityData?) {
        guard let pairId = pairedDevice?.pairId, let capability else { return }
        let sms = capability.features.sms
        settings.setPeerCanSend(settings.smsEnabled && sms?.enabled == true && sms?.canSend == true, pairId: pairId)
    }

    /// The call part of the connection events; a "Decline" from a notification waiting on the relay for a phone that
    /// is not there yet wakes it with `call_action` (CALL-02 API 6 logic 3).
    func callsLinkEvent(_ event: LinkEvent) {
        calls.linkEvent(event)
        switch event {
        case .connected(_, let details): storePeerCanSend(details.peerCapability)
        case .capabilityUpdated(let capability): storePeerCanSend(capability)
        case .status(let status): if callActionPending, status.status == .phoneOffline { wakePhoneForCallAction() }
        default: break
        }
    }

    private func wakePhoneForCallAction() {
        Task { await manager?.wakePhone(reason: .callAction) }
    }

    /// CALL-01 API 6 logic 3 and CALL-04 API 4 while the app is open: an incoming call shows as the in-app banner —
    /// from the push itself when no session brought it yet, connecting at the same time — and never as a system
    /// banner; a missed call only goes to Notification Center. `info` and `push` are what the notification's
    /// `userInfo` holds; `nil`: not a call notification.
    public func foregroundPresentation(info: CallNotificationInfo?, push: PushAlertFields?)
        -> UNNotificationPresentationOptions? {
        guard let push, push.envelope.type == .callEvent else {
            guard let info else { return nil }
            if case .missed = info { return [.list] }
            return []
        }
        guard let pairId = pairedDevice?.pairId, push.pairId == pairId,
              let prk = try? secrets.load(account: SecretAccount.pairKey(pairId: pairId)),
              let decoded = CallPushDecoder.decode(fields: push, nowMs: HLUUID.currentTimeMs(), prk: { _ in prk })
        else { return [.list] }
        switch decoded.content {
        case .incoming(let state):
            calls.pushed(state, envelopeTs: push.envelope.ts)
            if !connected { reconnectNow() }
            return []
        case .missed:
            return [.list]
        }
    }

    /// A response to one of the call notifications. "Decline" and "Message" run in a background task the app delegate
    /// holds, without bringing the app to the foreground (CALL-02 API 6, CALL-04 API 4).
    public func handleCallNotification(_ response: CallNotificationResponse) async {
        switch response {
        case .reject(let pairId, let callId, let startedAt):
            await declineCallFromNotification(pairId: pairId, callId: callId, startedAt: startedAt)
        case .message:
            _ = await replyToMissedCall(response)
        case .openMissed(_, let entryId, _):
            selectedTab = .calls
            await calls.markSeen(entryId)
        case .openIncoming, .answer:
            break // the app opens; the phone sends the call again once connected (CALL-01 E8)
        }
    }

    /// CALL-02 flow B: connect (LAN, then relay), send `reject` within `CALL_REJECT_BG_TIMEOUT` (15 s, the connection
    /// included); done or the call moved on → the notification goes; otherwise "Couldn't decline the call" (B3, E8).
    func declineCallFromNotification(pairId: String, callId: String, startedAt: Int64) async {
        guard pairId == pairedDevice?.pairId, HLUUID.currentTimeMs() - startedAt <= Self.callDeclineMaxAgeMs else {
            calls.notifier.removeIncoming(callId: callId, reader: callPushReader())
            return
        }
        let wasInBackground = !inForeground
        if wasInBackground { await manager?.systemDidWake() }
        callActionPending = true
        if link.status == .phoneOffline { wakePhoneForCallAction() }
        let outcome = await calls.controller.declineFromNotification(callId: callId, within: callRejectDeadline)
        callActionPending = false
        switch outcome {
        case .accepted, .failed(.callEnded), .failed(.answeredOnPhone):
            calls.notifier.removeIncoming(callId: callId, reader: callPushReader())
        default:
            calls.notifier.postDeclineFailed(callId: callId)
        }
        if wasInBackground, !inForeground { await manager?.systemWillSleep() }
    }

    /// CALL-04 API 4 "Message": like a quick reply (SMS-04 API 5) — connect, queue the SMS for the caller's number
    /// through the call's SIM, and wait about 20 s for the phone to accept; otherwise "Not sent yet", and the next
    /// opening sends it. An empty text after trimming is ignored (logic 4).
    func replyToMissedCall(_ response: CallNotificationResponse) async -> Bool {
        guard case .message(let pairId, let entryId, let callId, let number, let subId, let text) = response else {
            return false
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, pairId == pairedDevice?.pairId, let engine = smsEngine else { return false }
        let wasInBackground = !inForeground
        if wasInBackground { await manager?.systemDidWake() }
        let accepted = await engine.quickReply(text: body, toNumber: number, subId: subId, deadline: quickReplyDeadline)
        if !accepted {
            calls.notifier.postReplyNotSent(pairId: pairId, key: entryId.map(String.init) ?? callId ?? "")
        }
        await calls.markSeen(entryId)
        if wasInBackground, !inForeground { await manager?.systemWillSleep() }
        return accepted
    }

    /// PAIR-02 field 8 and the Calls row: why calls do not work with the phone, off on this device included, or `nil`.
    public var callsFeatureReason: String? {
        guard pairedDevice != nil else { return nil }
        guard calls.callsEnabled else { return L10n.Pairing.reasonOffOnDevice(deviceName: device.name) }
        return callsPhoneProblem
    }

    /// Why calls do not work with the phone while they are on here (SET-02, the Calls row), or `nil`.
    public var callsPhoneProblem: String? {
        guard calls.callsEnabled, let device = pairedDevice, let capability = device.peerCapability else { return nil }
        if capability.features.call?.enabled != true { return L10n.Pairing.reasonOffOnDevice(deviceName: device.peerName) }
        if CallPermissions.missing(CallPermissions.phoneState, in: capability.permissionsMissing ?? []) {
            return L10n.Pairing.reasonMissingPermission
        }
        return nil
    }
}
