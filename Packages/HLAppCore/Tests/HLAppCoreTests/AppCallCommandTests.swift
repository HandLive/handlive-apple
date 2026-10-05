import Foundation
import HLProtocol
import HLTransport
import Testing
@testable import HLAppCore

/// CALL-05 commands: Answer, Decline and End go out as `call_event/action` keyed by the app call's `call_id`, with the
/// phone's refusals mapped to what the panel says.
@Suite("App call commands: answer, decline, end")
@MainActor
struct AppCallCommandTests {
    private let callId = AppCallSamples.callId

    private func action(_ name: String) -> JSONValue {
        .object(["call_id": .string(AppCallSamples.callId), "action": .string(name)])
    }

    @Test("Answer: one call_event/action with the app call_id and no audio (phone); buttons lock until the next version")
    func answer() async {
        let peer = FakeCallPeer([.ok])
        let controller = AppCallController.connectedForTest(peer: peer)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.answer(.phone), for: callId) == .accepted)
        #expect(peer.sent.count == 1 && peer.sent[0].op == .action)
        #expect(peer.sent[0].data == action("answer"))
        #expect(controller.call?.command == .answer(.phone) && !controller.allows(.reject(reply: nil), for: callId))
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 200)
        #expect(controller.call?.command == nil && controller.call?.phase == .inCall)
    }

    @Test("Decline sends reject; End sends end, only while the phone's controls allow them")
    func declineAndEnd() async {
        let peer = FakeCallPeer([.ok, .ok])
        let controller = AppCallController.connectedForTest(peer: peer)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(!controller.allows(.end, for: callId))
        #expect(await controller.perform(.reject(reply: nil), for: callId) == .accepted)
        #expect(peer.sent[0].data == action("reject"))
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 200)
        #expect(controller.allows(.end, for: callId) && !controller.allows(.answer(.phone), for: callId))
        #expect(!controller.allows(.reject(reply: nil), for: callId))
        #expect(await controller.perform(.end, for: callId) == .accepted)
        #expect(peer.sent[1].data == action("end"))
    }

    @Test("Buttons follow controls per state: a missing answer or decline intent hides that button")
    func allowance() {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ringing(controls: AppCallControls(answer: false, decline: true)), envelopeTs: 100)
        #expect(!controller.allows(.answer(.phone), for: callId) && controller.allows(.reject(reply: nil), for: callId))
        controller.apply(AppCallSamples.ringing(controls: .none), envelopeTs: 200)
        #expect(!controller.allows(.reject(reply: nil), for: callId) && !controller.allows(.end, for: callId))
        controller.apply(AppCallSamples.ongoing(controls: .none), envelopeTs: 300) // no End action found
        #expect(!controller.allows(.end, for: callId))
        // The audio stays on the phone, and there is no SMS reply to an app call.
        #expect(!controller.allows(.answer(.mac), for: callId) && !controller.allows(.reject(reply: "text"), for: callId))
    }

    @Test("Without a call, or without a session, a command is not allowed or not sent")
    func nothingToDo() async {
        let controller = AppCallController.connectedForTest()
        #expect(await controller.perform(.end, for: callId) == .notAllowed)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        controller.disconnected()
        // No session: no ack in time.
        #expect(await controller.perform(.answer(.phone), for: callId) == .failed(.commandNotSent))
    }

    @Test("A command goes to the call_id it names, shown or not; an unknown call or one that ended gets nothing")
    func byCallId() async {
        let peer = FakeCallPeer([.ok])
        let controller = AppCallController.connectedForTest(peer: peer)
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 100)
        controller.apply(AppCallSamples.ringing(AppCallSamples.otherCallId), envelopeTs: 200) // shown: ringing first
        #expect(controller.call?.callId == AppCallSamples.otherCallId)
        #expect(controller.allows(.end, for: callId) && !controller.allows(.end, for: AppCallSamples.otherCallId))
        #expect(await controller.perform(.end, for: callId) == .accepted) // the ongoing call behind the ringing one
        #expect(peer.sent.count == 1 && peer.sent[0].data == action("end"))
        #expect(controller.call?.callId == AppCallSamples.otherCallId && controller.call?.command == nil)
        let unknown = "0192f3f0-dead-7c2d-8e3f-4a5b6c7d8e90"
        #expect(!controller.allows(.reject(reply: nil), for: unknown))
        #expect(await controller.perform(.reject(reply: nil), for: unknown) == .notAllowed)
        controller.apply(AppCallSamples.ended(AppCallSamples.otherCallId, reason: .declined), envelopeTs: 300)
        #expect(await controller.perform(.reject(reply: nil), for: AppCallSamples.otherCallId) == .notAllowed)
        #expect(peer.sent.count == 1)
    }

    @Test("A successful Answer sets answerRequested until the call moves on; the hint is the panel's")
    func answerRequested() async {
        let controller = AppCallController.connectedForTest(peer: FakeCallPeer([.ok]))
        controller.apply(AppCallSamples.ringing(mode: .tap), envelopeTs: 100)
        #expect(controller.call?.answerRequested == false)
        #expect(await controller.perform(.answer(.phone), for: callId) == .accepted)
        #expect(controller.call?.answerRequested == true)
        #expect(await eventually { controller.call?.command == nil }) // buttons unlock, the request stays known
        #expect(controller.call?.answerRequested == true)
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 200)
        #expect(controller.call?.answerRequested == false)
    }

    @Test("A refused or unanswered Answer does not count as requested")
    func answerRefused() async {
        let controller = AppCallController.connectedForTest(
            peer: FakeCallPeer([.refused(AppCallSamples.refused(.internal))]))
        controller.apply(AppCallSamples.ringing(mode: .tap), envelopeTs: 100)
        _ = await controller.perform(.answer(.phone), for: callId)
        #expect(controller.call?.answerRequested == false)
    }

    #if DEBUG
    @Test("Bench lines: app_call_received (not call_state_received), then tap, sent and ack with the app call_id; no names")
    func benchLines() async throws {
        let start = Date()
        let benchCall = "0192f3f0-b3c4-7c2d-8e3f-4a5b6c7d8e9b" // only this test uses it
        let controller = AppCallController.connectedForTest(peer: FakeCallPeer([.ok]))
        let envelope = try AppCallSamples.envelope(AppCallSamples.ringing(benchCall), ts: 100)
        controller.receive(envelope)
        #expect(await controller.perform(.reject(reply: nil), for: benchCall, from: .panel) == .accepted)
        let lines = try BenchLines.since(start).filter { $0.contains(" call=\(benchCall) ") }
        #expect(lines.contains {
            $0.contains("ev=app_call_received call=\(benchCall) env=\(envelope.id) peer=00000000 state=ringing")
        })
        #expect(!lines.contains { $0.contains("ev=call_state_received") })
        #expect(lines.contains { $0.contains("ev=call_action_tap call=\(benchCall) action=reject from=panel") })
        #expect(lines.contains { $0.contains("ev=call_action_sent call=\(benchCall) ") && $0.contains(" action=reject ") })
        #expect(lines.contains { $0.contains("ev=call_action_ack_received call=\(benchCall) ") && $0.hasSuffix(" ok=true") })
        #expect(!lines.contains { $0.contains("Nguy") || $0.contains("Telegram") || $0.contains("telegram") })
    }
    #endif

    // MARK: - Errors

    @Test("No ack in time: back to how it was with Couldn't send; the command is never sent again with a new id")
    func noAck() async {
        let peer = FakeCallPeer()
        let controller = AppCallController.connectedForTest(peer: peer)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.answer(.phone), for: callId) == .failed(.commandNotSent))
        #expect(controller.call?.problem == .commandNotSent && controller.call?.command == nil)
        #expect(peer.sent.count == 1)
    }

    @Test("A session lost while waiting: the same envelope id goes again once the session is back in time")
    func resendAfterReconnect() async {
        let timer = ManualClock()
        let lost = FakeCallPeer(otherwise: .sessionEnded)
        let controller = AppCallController.connectedForTest(peer: lost, timer: timer)
        controller.requestTimeout = .seconds(3)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        let back = FakeCallPeer([.ok])
        let command = Task { await controller.perform(.reject(reply: nil), for: callId) }
        await timer.waitForSleepers() // the dead session refused it: waiting to try again
        controller.disconnected()
        timer.advance(by: .milliseconds(100))
        await timer.waitForSleepers(2) // no session: still waiting, and so is "Lost connection"
        controller.connected(peer: back, capability: AppCallSamples.capability())
        timer.advance(by: .milliseconds(100))
        #expect(await command.value == .accepted)
        #expect(back.sent.count == 1 && !lost.sent.isEmpty)
        #expect(Set((lost.sent + back.sent).map(\.id)).count == 1)
    }

    @Test("CALL_APP_ACTION_UNAVAILABLE: the buttons unlock, that control is withdrawn until the next app_call refreshes it")
    func actionUnavailable() async {
        let controller = AppCallController.connectedForTest(
            peer: FakeCallPeer([.refused(AppCallSamples.refused(.callAppActionUnavailable))]))
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.answer(.phone), for: callId) == .notAllowed) // the phone no longer offers it
        #expect(controller.call?.command == nil && controller.call?.problem == nil)
        #expect(controller.call?.controls == AppCallControls(answer: false, decline: true))
        #expect(!controller.allows(.answer(.phone), for: callId) && controller.allows(.reject(reply: nil), for: callId))
        controller.apply(AppCallSamples.ringing(), envelopeTs: 200) // the phone's latest app_call wins
        #expect(controller.call?.controls == AppCallControls(answer: true, decline: true))
    }

    @Test("CALL_NOT_FOUND: the phone has forgotten the call, so the panel closes and the call never comes back")
    func notFound() async {
        let controller = AppCallController.connectedForTest(
            peer: FakeCallPeer([.refused(AppCallSamples.refused(.callNotFound))]))
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 100)
        #expect(await controller.perform(.end, for: callId) == .failed(.callEnded))
        #expect(controller.call == nil)
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 150) // the call is over: a late version stays away
        #expect(controller.call == nil)
    }

    @Test("FEATURE_DISABLED: app calls are not in effect for the session, so every app-call panel closes")
    func featureDisabled() async {
        let controller = AppCallController.connectedForTest(
            peer: FakeCallPeer([.refused(AppCallSamples.refused(.featureDisabled))]))
        controller.apply(AppCallSamples.ongoing(AppCallSamples.otherCallId), envelopeTs: 50)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.reject(reply: nil), for: callId) == .failed(.featureOffOnPhone))
        #expect(controller.call == nil && controller.contexts.isEmpty)
    }

    @Test("Any other refusal reads as Couldn't send the command, and the problem line can be cleared")
    func otherRefusal() async {
        let controller = AppCallController.connectedForTest(
            peer: FakeCallPeer([.refused(AppCallSamples.refused(.internal))]))
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.reject(reply: nil), for: callId) == .failed(.commandNotSent))
        #expect(controller.call?.problem == .commandNotSent && controller.call?.command == nil)
        controller.clearProblem()
        #expect(controller.call?.problem == nil)
    }

    @Test("The route error of an app call (audio = mac is never asked) reads as not sent")
    func routeFailed() async {
        let controller = AppCallController.connectedForTest(
            peer: FakeCallPeer([.refused(AppCallSamples.refused(.callRouteFailed))]))
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.answer(.phone), for: callId) == .failed(.commandNotSent))
    }
}
