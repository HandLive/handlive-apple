import Foundation
import HLAppCore
import HLCallNotifications
import HLTransport

extension MacCalls {
    /// The app call to show changed (CALL-05). A cellular call keeps the one panel while it exists; the app call shows
    /// when that call closes (`callChanged` brings it back).
    func appCallChanged(_ call: AppCall?) {
        currentAppCall = call
        guard controller.call == nil else { return }
        showAppCall(call)
    }

    /// The panel, VoiceOver announcement and ringtone of an app call, or nothing when there is none: the rules of a
    /// cellular call (CALL-01 step 7) without a communication notification, which an app call does not have.
    func showAppCall(_ call: AppCall?) {
        let focusState = focus.state
        let alert = CallAlert.of(call, notify: settings.callNotify, ringtone: settings.callRingtone, focus: focusState,
                                 answeredHere: call.map { answeredHere.contains($0.callId) } ?? false)
        panel.call = nil
        if let call, alert.panel {
            let newCall = panel.appCall?.callId != call.callId || !presenter.isShown
            panel.appCall = call
            panel.composing = false
            // VoiceOver reads the caller and the panel title when the panel comes up for a ringing call.
            let announce = newCall && call.phase == .ringing ? AppCallPanelPresentation(call, phoneName: "").announcement : nil
            presenter.show(callId: call.callId, content: .app, announce: announce)
        } else {
            presenter.hide()
            panel.appCall = nil
            panel.composing = false
        }
        updateAppCallRingtone(call, alert: alert)
        if let call, call.phase == .ringing, lastAlert?.callId != call.callId || lastAlert?.alert != alert {
            lastAlert = (call.callId, alert)
            BenchLog.event("call_alert", ["call": call.callId, "focus": focusState.rawValue,
                                          "panel": alert.panel ? "true" : "false", "ring": alert.ring ? "true" : "false",
                                          "level": alert.benchLevel])
        }
        if call == nil { answeredHere.removeAll() }
    }

    /// Like a cellular call: loops while the panel rings, stops when the call leaves `ringing` or a button is clicked,
    /// and a call rings at most once here.
    private func updateAppCallRingtone(_ call: AppCall?, alert: CallAlert) {
        guard let call, alert.ring else { return ringtone.stop() }
        guard !ringDone.contains(call.callId) else { return }
        ringDone.insert(call.callId)
        ringtone.start()
    }

    /// Answer, Decline or End from the panel of the app call `callId`: only that call, and only while it is live and
    /// allows the command (never the cellular call). The ringing stops at the first click.
    func appCommand(_ command: CallCommand, for callId: String, from source: CallActionSource) {
        guard appCalls.allows(command, for: callId) else { return }
        ringDone.insert(callId)
        ringtone.stop()
        if case .answer = command { answeredHere.insert(callId) }
        Task { await appCalls.perform(command, for: callId, from: source) }
    }

    /// "Ignore" on the panel of the app call `callId`: that call hides and stops ringing here (its new version closes
    /// the panel); the phone keeps ringing.
    func ignoreAppCall(_ callId: String) {
        appCalls.ignore(callId: callId)
    }

    // MARK: - Settings (SET-02 `call.app_calls`)

    /// `call.app_calls` travels in the capability, so the phone stops sending app calls; off closes the panel here.
    public func setCallAppCalls(_ enabled: Bool) {
        settings.callAppCalls = enabled
        callAppCalls = enabled
        capabilityChanged()
        appCalls.settingChanged()
    }
}
