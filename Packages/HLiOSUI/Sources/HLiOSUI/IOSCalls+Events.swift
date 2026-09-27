import Foundation
import HLAppCore
import HLCallNotifications
import HLCalls
import HLProtocol
import HLTransport

extension IOSCalls {
    /// The phone's call changed: the banner and the system's incoming-call notification follow it (CALL-01 step 12).
    func callChanged(_ call: ActiveCall?) {
        updateIncomingNotification(call)
        updateBanner(call)
    }

    /// The banner shows a ringing or waiting call while call notifications are on (E3); VoiceOver reads "Incoming call
    /// from …" when it comes up for a call (special requirements).
    func updateBanner(_ call: ActiveCall?) {
        guard let call, settings.callNotify, call.phase == .ringing || call.phase == .waiting else {
            banner = nil
            return
        }
        banner = call
        guard announcedCallId != call.callId else { return }
        announcedCallId = call.callId
        announce(CallNames.incomingAnnouncement(call.waitingCaller ?? call.caller))
        BenchLog.event("call_banner_shown", ["call": call.callId])
    }

    /// The phone does not push when a call stops ringing, so the app removes the incoming-call notification itself:
    /// once the call is no longer `ringing`, or as soon as it first shows up in another state (API 6 logic 4).
    private func updateIncomingNotification(_ call: ActiveCall?) {
        if let ringing = incomingCallId, call?.callId != ringing || call?.phase != .ringing {
            removeIncoming(ringing)
            incomingCallId = nil
        }
        guard let call else { return }
        if call.phase == .ringing {
            incomingCallId = call.callId
        } else if clearedCallId != call.callId {
            removeIncoming(call.callId)
        }
    }

    private func removeIncoming(_ callId: String) {
        clearedCallId = callId
        notifier.removeIncoming(callId: callId, reader: pushReader())
    }

    /// The controller's events: a missed call without the phone's call log (flow A). iPhone and iPad have no
    /// "Decline with Message…", so no reply to send.
    func handle(_ event: CallEvent) {
        if case .missed(let missed) = event { notifyMissed(missed) }
    }

    /// The call log's events: missed calls from `log_new`, the badge, removals (CALL-04 steps 9–12).
    func handle(_ event: CallLogEvent) {
        list?.apply(event)
        switch event {
        case .missed(let missed): notifyMissed(missed)
        case .badge(let count): missedBadge = count
        case .removeMissedNotifications(let pairId, let entryId): notifier.removeMissed(pairId: pairId, entryId: entryId)
        case .status: break
        }
    }

    /// One notification per missed call while the app runs (E8: not with `call.notify` off), "Message" when there is
    /// a number and SMS can go out (E10).
    func notifyMissed(_ missed: MissedCall) {
        guard settings.callNotify, settings.callsEnabled else { return }
        notifier.postMissed(missed, canMessage: missed.number != nil && smsCanSend())
    }

    /// A tap on a missed-call notification, or "Message" sent from it: the entry is seen (step 12).
    func markSeen(_ entryId: Int64?) async {
        guard let entryId else { return }
        await logEngine?.markSeen(entryId: entryId)
    }

    // MARK: - Settings (SET-02 fields 10–11)

    /// `feature.call` travels in the capability; off closes the banner and every call notification here.
    public func setCallsEnabled(_ enabled: Bool) {
        settings.callsEnabled = enabled
        callsEnabled = enabled
        capabilityChanged()
        controller.settingChanged()
        if !enabled { notifier.removeAllCalls() }
    }

    /// `call.notify` travels in the capability: off, the phone stops pushing calls here and the app shows no banner
    /// and no missed-call notification (E3, CALL-04 E8).
    public func setCallNotify(_ enabled: Bool) {
        settings.callNotify = enabled
        callNotify = enabled
        capabilityChanged()
        updateBanner(controller.call)
    }
}
