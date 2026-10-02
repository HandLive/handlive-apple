import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLTransport
import Testing
@testable import HLMacUI

/// CALL-05 on the Mac: the panel for a call of another app comes up as soon as its `app_call` arrives, with the app's
/// name; Answer, Decline and End go to the phone; the cellular call keeps the panel while it lasts; the Settings row
/// turns the feature off and tells the phone.
@Suite("Mac app model: calls from other apps")
@MainActor
struct AppModelAppCallsTests {
    func ready(_ stubs: CallStubs, peer: OkCallPeer = OkCallPeer(),
               capability: CapabilityData = MacCallSamples.capability()) throws -> AppModel {
        let model = makeModel(calls: stubs)
        model.launch()
        try model.completePairing(PairingControllerTests.result())
        model.calls.controller.connected(peer: peer, capability: capability)
        model.calls.appCalls.connected(peer: peer, capability: capability)
        return model
    }

    @Test("Ringing: the panel at once with the app and caller, VoiceOver, the ringtone; no notification, no menu item")
    func ringing() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        #expect(stubs.presenter.isShown && stubs.presenter.shownCallId == MacAppCallSamples.callId)
        #expect(stubs.presenter.shownContent == .app) // its bench line is app_call_panel_shown
        #expect(stubs.presenter.announcements == [
            "\(L10n.A11y.callIncomingFrom(caller: "Nguyễn Văn A")), \(L10n.Call.appIncomingTitle(appName: "Telegram"))",
        ])
        #expect(stubs.ringtone.isPlaying && stubs.notifier.incoming.isEmpty)
        #expect(model.calls.panel.appCall?.appName == "Telegram" && model.calls.panel.call == nil)
        #expect(model.calls.ringingCall == nil) // the menu bar menu lists cellular calls only
    }

    @Test("The panel follows the message: app_call over the link opens it, ended closes it")
    func overTheLink() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.linkEvent(.message(try MacAppCallSamples.envelope(MacAppCallSamples.ringing(), ts: 100)))
        #expect(stubs.presenter.isShown && model.calls.panel.appCall?.phase == .ringing)
        model.calls.linkEvent(.message(try MacAppCallSamples.envelope(MacAppCallSamples.ended(reason: .missed), ts: 200)))
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying && model.calls.panel.appCall == nil)
    }

    @Test("An answered call that ends closes the in-call panel at once, with no Call ended state")
    func endedClosesAtOnce() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        model.calls.appCalls.apply(MacAppCallSamples.ongoing(), envelopeTs: 200)
        #expect(stubs.presenter.isShown && model.calls.panel.appCall?.phase == .inCall)
        let over = MacAppCallSamples.ended(reason: .ended, answeredAt: MacAppCallSamples.startedAt + 5000)
        model.calls.appCalls.apply(over, envelopeTs: 300)
        #expect(!stubs.presenter.isShown && model.calls.panel.appCall == nil)
        model.calls.appCalls.apply(MacAppCallSamples.ongoing(), envelopeTs: 400) // nothing after ended
        #expect(!stubs.presenter.isShown)
    }

    @Test("Answer sends the app call_id without audio (phone) and stops the ringing; the in-call panel follows")
    func answer() async throws {
        let stubs = CallStubs()
        let peer = OkCallPeer()
        let model = try ready(stubs, peer: peer)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(mode: .tap), envelopeTs: 100)
        model.calls.panel.appCommand(.answer(.phone), MacAppCallSamples.callId)
        #expect(!stubs.ringtone.isPlaying)
        #expect(await eventually { peer.sent.first?.action == .answer })
        #expect(peer.sent.first == CallActionRequest(callId: MacAppCallSamples.callId, action: .answer))
        #expect(await eventually { model.calls.panel.appCall?.answerRequested == true })
        model.calls.appCalls.apply(MacAppCallSamples.ongoing(), envelopeTs: 200)
        #expect(stubs.presenter.isShown && model.calls.panel.appCall?.phase == .inCall && !stubs.ringtone.isPlaying)
    }

    @Test("Decline sends reject; End sends end; each for the app call_id")
    func declineAndEnd() async throws {
        let stubs = CallStubs()
        let peer = OkCallPeer()
        let model = try ready(stubs, peer: peer)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        model.calls.panel.appCommand(.reject(reply: nil), MacAppCallSamples.callId)
        #expect(await eventually { peer.sent.count == 1 })
        model.calls.appCalls.apply(MacAppCallSamples.ongoing(), envelopeTs: 200)
        model.calls.panel.appCommand(.end, MacAppCallSamples.callId)
        #expect(await eventually { peer.sent.count == 2 })
        #expect(peer.sent.map(\.action) == [.reject, .end])
        #expect(peer.sent.allSatisfy { $0.callId == MacAppCallSamples.callId })
    }

    @Test("Ignore closes the panel and silences the Mac; the call never rings again")
    func ignore() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(caller: nil), envelopeTs: 100)
        model.calls.panel.appIgnore(MacAppCallSamples.callId)
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 150) // the caller's name arrives
        #expect(!stubs.presenter.isShown && stubs.ringtone.starts == 1)
    }

    @Test("Focus on: nothing; Focus not readable: the panel without ringing; Ring on Mac off: silent panel")
    func focusAndRingtone() throws {
        let stubs = CallStubs()
        stubs.focus.state = .on
        let model = try ready(stubs)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying && stubs.notifier.incoming.isEmpty)
        let unknown = CallStubs()
        unknown.focus.state = .unknown
        let other = try ready(unknown)
        other.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        #expect(unknown.presenter.isShown && !unknown.ringtone.isPlaying)
        let unavailable = CallStubs()
        unavailable.focus.state = .unavailable
        let ringing = try ready(unavailable)
        ringing.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        #expect(unavailable.presenter.isShown && unavailable.ringtone.isPlaying)
        let quiet = CallStubs()
        let silent = try ready(quiet)
        silent.calls.setCallRingtone(false)
        silent.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        #expect(quiet.presenter.isShown && !quiet.ringtone.isPlaying)
    }

    @Test("Call notifications off: no panel and no ringing for an app call either; on again brings it back")
    func notifyOff() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.setCallNotify(false)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying)
        model.calls.setCallNotify(true)
        #expect(stubs.presenter.isShown && stubs.ringtone.isPlaying)
    }

    @Test("A cellular call keeps the one panel while it lasts; the live app call shows when it closes")
    func cellularCallHasPriority() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 200)
        #expect(model.calls.panel.call?.callId == MacCallSamples.callId && model.calls.panel.appCall == nil)
        #expect(stubs.presenter.shownCallId == MacCallSamples.callId && stubs.presenter.shownContent == .cellular)
        model.calls.controller.apply(MacCallSamples.idleMissed(), envelopeTs: 300)
        #expect(model.calls.panel.call == nil && model.calls.panel.appCall?.callId == MacAppCallSamples.callId)
        #expect(stubs.presenter.isShown && stubs.presenter.shownCallId == MacAppCallSamples.callId)
        #expect(stubs.presenter.shownContent == .app)
        // And the other way: an app call that rings during a cellular call does not take the panel.
        let busy = try ready(CallStubs())
        busy.calls.controller.apply(MacCallSamples.offhook(), envelopeTs: 100)
        busy.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 200)
        #expect(busy.calls.panel.call?.phase == .inCall && busy.calls.panel.appCall == nil)
    }

    @Test("Turning Calls from Other Apps off closes the call, tells the phone, and an off phone shows nothing")
    func settingOff() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        var capabilityUpdates = 0
        model.calls.capabilityChanged = { capabilityUpdates += 1 }
        #expect(model.calls.callAppCalls && model.device.capability(settings: model.settings).features.call?.appCalls == true)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        model.calls.setCallAppCalls(false)
        #expect(!model.calls.callAppCalls && !model.settings.callAppCalls && capabilityUpdates == 1)
        #expect(model.device.capability(settings: model.settings).features.call?.appCalls == false)
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying && model.calls.panel.appCall == nil)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 200)
        #expect(!stubs.presenter.isShown)
        model.calls.setCallAppCalls(true)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 300)
        #expect(stubs.presenter.isShown)
    }

    @Test("The Calls switch off closes an app call too; the phone turning app calls off closes it")
    func switchesOff() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        model.calls.setCallsEnabled(false)
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying)
        #expect(model.device.capability(settings: model.settings).features.call?.appCalls == false) // 0.7.2
        model.calls.setCallsEnabled(true)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 200)
        #expect(stubs.presenter.isShown)
        model.calls.linkEvent(.capabilityUpdated(MacCallSamples.capability(appCalls: false)))
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying)
    }

    @Test("A phone without CALL-05 (no app_calls) never opens a panel")
    func olderPhone() throws {
        let stubs = CallStubs()
        let model = try ready(stubs, capability: MacCallSamples.capability(appCalls: nil))
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        #expect(!stubs.presenter.isShown)
    }

    @Test("Delete All HandLive Data and a pair change take the app call away")
    func goesWithThePair() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        model.calls.setPair(nil)
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying)
    }

    @Test("Why app calls do not reach the Mac: no Notification access, or off on the phone; nothing when it works")
    func reasons() throws {
        let model = try ready(CallStubs())
        #expect(model.appCallsFeatureReason == nil) // no capability stored yet
        model.updatePairRecord { $0.peerCapability = MacCallSamples.capability() }
        #expect(model.appCallsFeatureReason == nil)
        model.updatePairRecord {
            $0.peerCapability = MacCallSamples.capability(appCalls: false, missing: ["NOTIFICATION_LISTENER"])
        }
        #expect(model.appCallsFeatureReason == L10n.Pairing.reasonMissingPermission)
        model.updatePairRecord { $0.peerCapability = MacCallSamples.capability(appCalls: false) }
        #expect(model.appCallsFeatureReason == L10n.Pairing.reasonOffOnDevice(deviceName: model.pairedDevice?.peerName ?? ""))
        model.updatePairRecord { $0.peerCapability = MacCallSamples.capability(appCalls: nil) }
        #expect(model.appCallsFeatureReason == nil) // a phone build without CALL-05 says nothing
        model.updatePairRecord { $0.peerCapability = MacCallSamples.capability(appCalls: false) }
        model.calls.setCallAppCalls(false)
        #expect(model.appCallsFeatureReason == nil) // off here: nothing to explain
        model.calls.setCallAppCalls(true)
        model.calls.setCallsEnabled(false)
        #expect(model.appCallsFeatureReason == nil) // the Calls switch has its own reason
    }

    @Test("Notification access is no generic missing permission: its reason is on the app calls row")
    func notificationAccessIsNotGeneric() {
        #expect(!MissingPermissionsSection.hasOwnPhase("NOTIFICATION_LISTENER"))
        #expect(!MissingPermissionsSection.hasOwnPhase("android.permission.NOTIFICATION_LISTENER"))
        #expect(MissingPermissionsSection.hasOwnPhase("CAMERA"))
    }
}
