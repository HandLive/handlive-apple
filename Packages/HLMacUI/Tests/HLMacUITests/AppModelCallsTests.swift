import Foundation
import HLAppCore
import HLCallNotifications
import HLLocalization
import HLProtocol
import HLSMS
import HLTransport
import Testing
@testable import HLMacUI

/// CALL-01 step 7, API 5 and API 7 on the Mac: one visible layer per call — the panel (with VoiceOver and the ringtone)
/// or, during a Focus, a time-sensitive notification; the commands from the panel, the menu and the notifications.
@Suite("Mac app model: calls")
@MainActor
struct AppModelCallsTests {
    func ready(_ stubs: CallStubs, peer: OkCallPeer = OkCallPeer(),
               capability: CapabilityData = MacCallSamples.capability()) throws -> AppModel {
        let model = makeModel(calls: stubs)
        model.launch()
        try model.completePairing(PairingControllerTests.result())
        model.calls.controller.connected(peer: peer, capability: capability)
        return model
    }

    @Test("Ringing: the panel with VoiceOver, the ringtone and a passive notification; answered: only the in-call panel")
    func ringing() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 100)
        #expect(stubs.presenter.isShown && stubs.ringtone.isPlaying)
        #expect(stubs.presenter.announcements == [L10n.A11y.callIncomingFrom(caller: "Nguyễn Văn A")])
        #expect(stubs.notifier.incoming[MacCallSamples.callId] == .passive)
        #expect(model.calls.ringingCall?.callId == MacCallSamples.callId)
        model.calls.controller.apply(MacCallSamples.offhook(), envelopeTs: 200)
        #expect(stubs.presenter.isShown && !stubs.ringtone.isPlaying && stubs.notifier.incoming.isEmpty)
        #expect(model.calls.panel.call?.phase == .inCall && model.calls.ringingCall == nil)
    }

    @Test("Focus on: no panel, no ringing, a time-sensitive notification; Focus not readable: the panel without ringing")
    func focus() throws {
        let stubs = CallStubs()
        stubs.focus.state = .on
        let model = try ready(stubs)
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 100)
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying)
        #expect(stubs.notifier.incoming[MacCallSamples.callId] == .timeSensitive)
        #expect(model.calls.ringingCall != nil) // the menu bar menu keeps the call
        let unknown = CallStubs()
        unknown.focus.state = .unknown
        let other = try ready(unknown)
        other.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 100)
        #expect(unknown.presenter.isShown && !unknown.ringtone.isPlaying)
        #expect(unknown.notifier.incoming[MacCallSamples.callId] == .passive)
    }

    @Test("Call notifications off: no panel, no ringing, no notification — only the menu (E3); Ring on Mac off: silent")
    func notifyOff() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.setCallNotify(false)
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 100)
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying && stubs.notifier.incoming.isEmpty)
        #expect(model.calls.ringingCall != nil)
        model.calls.setCallNotify(true)
        #expect(stubs.presenter.isShown && stubs.ringtone.isPlaying)
        model.calls.setCallRingtone(false)
        #expect(!stubs.ringtone.isPlaying && stubs.presenter.isShown)
    }

    @Test("Ignore closes the panel and silences the Mac; the call stays in the menu and never rings again")
    func ignore() throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        model.calls.controller.apply(MacCallSamples.ringing(number: nil), envelopeTs: 100)
        model.calls.ignore()
        #expect(!stubs.presenter.isShown && !stubs.ringtone.isPlaying && model.calls.ringingCall != nil)
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 150) // the number arrives (E10)
        #expect(!stubs.presenter.isShown && stubs.ringtone.starts == 1)
    }

    @Test("Answer from the notification during a Focus sends the command and opens the in-call panel")
    func answerFromNotification() async throws {
        let stubs = CallStubs()
        stubs.focus.state = .on
        let peer = OkCallPeer()
        let model = try ready(stubs, peer: peer)
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 100)
        let pairId = try #require(model.pairedDevice?.pairId)
        model.calls.handleNotification(.answer(pairId: pairId, callId: MacCallSamples.callId))
        #expect(await eventually { peer.sent.first?.action == .answer })
        model.calls.controller.apply(MacCallSamples.offhook(), envelopeTs: 200)
        #expect(stubs.presenter.isShown && stubs.notifier.incoming.isEmpty)
    }

    @Test("Decline with Message: the reply joins the SMS outbox for the caller once the decline is accepted")
    func declineWithMessage() async throws {
        let stubs = CallStubs()
        let model = try ready(stubs)
        let messages = try #require(model.messages)
        let pairId = try #require(messages.pairId)
        #expect(model.calls.quickReplies == [L10n.Call.quickReplyCallBack, L10n.Call.quickReplyInMeeting])
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 100)
        model.calls.panel.reply(L10n.Call.quickReplyInMeeting)
        #expect(!stubs.ringtone.isPlaying)
        #expect(await eventually {
            let pending = (try? messages.store.database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sms_outbox WHERE pair_id = ?", arguments: [pairId]) ?? 0
            }) ?? 0
            return pending == 1
        })
    }

    @Test("A missed call without the call log is notified, with Message only for a number, and joins the menu")
    func missedFlowA() throws {
        let stubs = CallStubs()
        let model = try ready(stubs, capability: MacCallSamples.capability(callLog: false))
        model.calls.controller.apply(MacCallSamples.ringing(number: nil), envelopeTs: 100)
        model.calls.controller.apply(MacCallSamples.idleMissed(), envelopeTs: 200)
        #expect(stubs.notifier.missed.count == 1 && stubs.notifier.missed.first?.1 == false)
        #expect(stubs.notifier.missed.first?.0.caller == .unknownCaller)
        #expect(model.calls.recentMissed.count == 1 && !stubs.presenter.isShown && stubs.notifier.incoming.isEmpty)
    }

    @Test("Quick replies keep the user's list; Ring on Mac asks for the Focus status once")
    func settings() async throws {
        let stubs = CallStubs()
        stubs.focus.isAuthorized = false
        let model = try ready(stubs)
        model.calls.setQuickReplies([" On my way ", "", "Later"])
        #expect(model.calls.quickReplies == ["On my way", "Later"] && model.calls.panel.quickReplies.count == 2)
        model.calls.setCallRingtone(false)
        model.calls.setCallRingtone(true)
        #expect(await eventually { stubs.focus.requests == 1 })
        #expect(!model.calls.focusAuthorized)
        model.calls.setCallsEnabled(false)
        #expect(!model.settings.callsEnabled && stubs.notifier.removedAll == 1)
    }
}
