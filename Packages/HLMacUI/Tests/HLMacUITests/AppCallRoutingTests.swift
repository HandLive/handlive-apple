import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import Testing
@testable import HLMacUI

/// CALL-05 on the Mac: every command goes to the call its UI shows, by `call_id` — the cellular call's panel, menu items
/// and notifications never reach an app call, the app-call panel never reaches the cellular call, and a call that is gone
/// gets nothing; and the bench lines of an app call (shared/tools/bench/README.md), which never carry a name.
@Suite("Mac app model: app call routing and bench lines")
@MainActor
struct AppCallRoutingTests {
    func ready(_ stubs: CallStubs, peer: OkCallPeer) throws -> AppModel {
        try AppModelAppCallsTests().ready(stubs, peer: peer)
    }

    @Test("The cellular call's panel, menu and notifications never act on an app call, whatever is left of them")
    func cellularSourcesSkipAppCalls() async throws {
        let stubs = CallStubs()
        let peer = OkCallPeer()
        let model = try ready(stubs, peer: peer)
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 100)
        model.calls.controller.apply(MacCallSamples.idleMissed(), envelopeTs: 200) // the cellular call is over
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 300)
        #expect(model.calls.controller.call == nil && model.calls.panel.appCall != nil)
        let pairId = try #require(model.pairedDevice?.pairId)
        // A stale menu item, the cellular panel's buttons and a notification action of the call that is over.
        model.calls.command(.answer(.phone), for: MacCallSamples.callId, from: .menu)
        model.calls.command(.reject(reply: nil), for: MacCallSamples.callId, from: .menu)
        model.calls.panel.answer()
        model.calls.panel.decline()
        model.calls.panel.reply(L10n.Call.quickReplyInMeeting)
        model.calls.panel.end()
        model.calls.panel.ignore()
        model.calls.handleNotification(.answer(pairId: pairId, callId: MacCallSamples.callId))
        model.calls.handleNotification(.reject(pairId: pairId, callId: MacCallSamples.callId, startedAt: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(peer.sent.isEmpty && stubs.ringtone.isPlaying && stubs.presenter.isShown)
        #expect(model.calls.panel.appCall?.ignored == false && model.calls.panel.appCall?.command == nil)
    }

    @Test("The app-call panel acts on its own call_id only: never the cellular call, never a call that is gone")
    func appPanelActsOnItsCall() async throws {
        let stubs = CallStubs()
        let peer = OkCallPeer()
        let model = try ready(stubs, peer: peer)
        model.calls.appCalls.apply(MacAppCallSamples.ringing(), envelopeTs: 100)
        let gone = "0192f3f0-dead-7c2d-8e3f-4a5b6c7d8e90"
        model.calls.panel.appCommand(.reject(reply: nil), gone)
        model.calls.panel.appIgnore(gone)
        try await Task.sleep(for: .milliseconds(100))
        #expect(peer.sent.isEmpty && stubs.ringtone.isPlaying && stubs.presenter.isShown)
        // A cellular call takes the panel: its Decline goes to it, the app call's (stale) Decline to the app call.
        model.calls.controller.apply(MacCallSamples.ringing(), envelopeTs: 200)
        model.calls.panel.decline()
        #expect(await eventually { peer.sent.count == 1 })
        model.calls.panel.appCommand(.reject(reply: nil), MacAppCallSamples.callId)
        #expect(await eventually { peer.sent.count == 2 })
        #expect(peer.sent == [CallActionRequest(callId: MacCallSamples.callId, action: .reject),
                              CallActionRequest(callId: MacAppCallSamples.callId, action: .reject)])
    }

    #if DEBUG
    @Test("Bench lines: app_call_received, then the app call's tap from the panel, sent and ack; no names")
    func benchLines() async throws {
        let start = Date()
        let stubs = CallStubs()
        let peer = OkCallPeer()
        let model = try ready(stubs, peer: peer)
        let envelope = try MacAppCallSamples.envelope(MacAppCallSamples.ringing(), ts: 100)
        model.calls.linkEvent(.message(envelope))
        #expect(stubs.presenter.shownContent == .app)
        model.calls.panel.appCommand(.answer(.phone), MacAppCallSamples.callId)
        #expect(await eventually { model.calls.panel.appCall?.answerRequested == true })
        let call = MacAppCallSamples.callId
        let lines = try BenchLines.since(start).filter { $0.contains(" call=\(call)") }
        let received = "ev=app_call_received call=\(call) env=\(envelope.id) "
        #expect(lines.contains { $0.contains(received) && $0.hasSuffix(" state=ringing") })
        #expect(!lines.contains { $0.contains("ev=call_state_received") })
        #expect(lines.contains { $0.contains("ev=call_action_tap call=\(call) action=answer from=panel") })
        #expect(lines.contains { $0.contains("ev=call_action_sent call=\(call) ") && $0.contains(" action=answer ") })
        #expect(lines.contains { $0.contains("ev=call_action_ack_received call=\(call) ") && $0.hasSuffix(" ok=true") })
        #expect(!lines.contains { $0.contains("Nguy") || $0.contains("Telegram") })
        #expect(CallPanelContent.app.shownEvent == "app_call_panel_shown")
        #expect(CallPanelContent.cellular.shownEvent == "call_panel_shown")
    }
    #endif
}
