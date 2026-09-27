import Foundation
import HLAppCore
import HLCallNotifications
import HLCalls
import HLProtocol

extension MacCalls {
    /// Answer, Decline, Decline with Message… and End from the panel, the menu or a notification (CALL-02, CALL-03).
    /// The ringing stops at the first click.
    func command(_ command: CallCommand, from source: CallActionSource) {
        guard let call = controller.call else { return }
        ringDone.insert(call.callId)
        ringtone.stop()
        if case .answer = command { answeredHere.insert(call.callId) }
        Task { await controller.perform(command, from: source) }
    }

    /// A response to one of HandLive's call notifications; the actions run in the running app without opening a
    /// window (CALL-01 API 7 logic 4, CALL-04 API 4).
    public func handleNotification(_ response: CallNotificationResponse) {
        switch response {
        case .answer(_, let callId), .reject(_, let callId, _), .openIncoming(_, let callId):
            guard controller.call?.callId == callId else { return }
            switch response {
            case .answer: command(.answer(.phone), from: .notification)
            case .reject: command(.reject(reply: nil), from: .notification)
            default: controller.showAgain() // the panel comes back unless a Focus is still on
            }
        case .message(_, let entryId, _, let number, let subId, let text):
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return } // logic 4
            Task { await sendSms(number, subId, body) }
            markSeen(entryId)
        case .openMissed(_, let entryId, _):
            showCallList()
            markSeen(entryId)
        }
    }

    private func markSeen(_ entryId: Int64?) {
        guard let entryId else { return }
        Task { await logEngine?.markSeen(entryId: entryId) }
    }

    /// The controller's events: a missed call without the phone's call log (flow A), a quick reply to send.
    func handle(_ event: CallEvent) {
        switch event {
        case .missed(let missed):
            notifyMissed(missed)
        case .sendReply(_, let number, let subId, let body):
            Task { await sendSms(number, subId, body) }
        }
    }

    /// The call log's events: missed calls from `log_new`, the badge, removals (CALL-04 steps 9–12).
    func handle(_ event: CallLogEvent) {
        list?.apply(event)
        switch event {
        case .missed(let missed): notifyMissed(missed)
        case .badge(let count): missedBadge = count
        case .removeMissedNotifications(let pairId, let entryId):
            notifier.removeMissed(pairId: pairId, entryId: entryId)
            if entryId == nil { recentMissed.removeAll() } else { recentMissed.removeAll { $0.entryId == entryId } }
        case .status: break
        }
    }

    /// One notification per missed call (E8: not with `call.notify` off), "Message" when there is a number and SMS can
    /// go out (E10); the call also joins the recent items of the menu bar menu.
    func notifyMissed(_ missed: MissedCall) {
        guard settings.callNotify, settings.callsEnabled else { return }
        notifier.postMissed(missed, canMessage: missed.number != nil && smsCanSend())
        recentMissed.insert(missed, at: 0)
        if recentMissed.count > 3 { recentMissed.removeLast(recentMissed.count - 3) }
    }

    // MARK: - Settings (SET-02 fields 10–12, CALL-02 field 8)

    /// `feature.call` travels in the capability; off closes the panel and every call notification here.
    public func setCallsEnabled(_ enabled: Bool) {
        settings.callsEnabled = enabled
        callsEnabled = enabled
        capabilityChanged()
        controller.settingChanged()
        if !enabled { notifier.removeAllCalls() }
    }

    /// `call.notify` is local on the Mac: off → no panel, no ringing, no notifications; the menu keeps the call (E3).
    public func setCallNotify(_ enabled: Bool) {
        settings.callNotify = enabled
        callNotify = enabled
        callChanged(controller.call)
    }

    /// `call.ringtone`: turning it on asks once to read the Focus status, without which the Mac never rings
    /// (API 5 logic 3).
    public func setCallRingtone(_ enabled: Bool) {
        settings.callRingtone = enabled
        callRingtone = enabled
        guard enabled else { return callChanged(controller.call) }
        Task {
            focusAuthorized = await focus.requestAuthorization()
            callChanged(controller.call)
        }
    }

    /// The Quick Replies list (at most 6 × 160 characters).
    public func setQuickReplies(_ replies: [String]) {
        settings.quickReplies = replies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        quickReplies = settings.quickReplies ?? []
        panel.quickReplies = quickReplies
    }

    /// The Focus permission may have changed in System Settings (the app became active).
    func refreshFocus() {
        focusAuthorized = focus.isAuthorized
    }
}
