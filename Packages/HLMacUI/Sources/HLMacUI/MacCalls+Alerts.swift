import Foundation
import HLAppCore
import HLCallNotifications
import HLTransport

extension MacCalls {
    /// The phone's call changed: the panel, the ringtone, the communication notification and the menu bar follow it,
    /// with one visible layer per call (CALL-01 step 7 and 12, API 7 logic 1).
    func callChanged(_ call: ActiveCall?) {
        let focusState = focus.state
        let alert = CallAlert.of(call, notify: settings.callNotify, ringtone: settings.callRingtone, focus: focusState,
                                 answeredHere: call.map { answeredHere.contains($0.callId) } ?? false)
        ringingCall = call?.phase == .ringing ? call : nil
        if call == nil {
            showAppCall(currentAppCall) // no cellular call: the panel is the app call's, or closes
        } else {
            updatePanel(call, alert: alert)
            updateRingtone(call, alert: alert)
        }
        updateNotification(call, alert: alert)
        if let call, call.phase == .ringing, lastAlert?.callId != call.callId || lastAlert?.alert != alert {
            lastAlert = (call.callId, alert)
            BenchLog.event("call_alert", ["call": call.callId, "focus": focusState.rawValue,
                                          "panel": alert.panel ? "true" : "false", "ring": alert.ring ? "true" : "false",
                                          "level": alert.benchLevel])
        }
        if call == nil { answeredHere.formIntersection(currentAppCall.map { [$0.callId] } ?? []) }
    }

    private func updatePanel(_ call: ActiveCall?, alert: CallAlert) {
        guard let call, alert.panel else {
            presenter.hide()
            panel.call = nil
            panel.appCall = nil
            panel.composing = false
            return
        }
        panel.appCall = nil // the cellular call has the panel; an app call waits for it
        let newCall = panel.call?.callId != call.callId || !presenter.isShown
        panel.call = call
        panel.canReplyBySms = smsCanSend()
        panel.quickReplies = quickReplies
        // VoiceOver reads "Incoming call from …" when the panel comes up for a ringing call (special requirements).
        let announce = newCall && call.phase == .ringing ? CallNames.incomingAnnouncement(call.caller) : nil
        presenter.show(callId: call.callId, content: .cellular, announce: announce)
    }

    /// Loops while the panel rings a call, stops when the call leaves `ringing`, a button is clicked, or after 60 s
    /// (field 10); a call rings at most once here, so it never starts again after it stopped.
    private func updateRingtone(_ call: ActiveCall?, alert: CallAlert) {
        guard let call, alert.ring else { return ringtone.stop() }
        guard !ringDone.contains(call.callId) else { return }
        ringDone.insert(call.callId)
        ringtone.start()
    }

    /// Passive while the panel shows, time-sensitive during a Focus, removed when the call is no longer ringing
    /// (API 7 logic 1–3).
    private func updateNotification(_ call: ActiveCall?, alert: CallAlert) {
        if let notified = notifiedCallId, notified != call?.callId || alert.notification == nil {
            notifier.removeIncoming(callId: notified)
            notifiedCallId = nil
        }
        guard let call, let level = alert.notification, let pairId else { return }
        notifier.postIncoming(call.state, pairId: pairId, level: level)
        notifiedCallId = call.callId
    }

    /// "Ignore" on the cellular call's panel (field 9): the panel closes and the Mac stops ringing; the phone keeps
    /// ringing and the menu keeps the call. It ignores only the call that panel shows, never an app call.
    func ignore() {
        guard let callId = panel.call?.callId, controller.call?.callId == callId else { return }
        ringtone.stop()
        controller.ignore()
    }
}
