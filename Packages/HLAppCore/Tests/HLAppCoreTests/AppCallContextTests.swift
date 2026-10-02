import Foundation
import HLProtocol
import HLTransport
import Testing
@testable import HLAppCore

/// CALL-05 on the client: which version of an app call is shown, how it moves ringing → ongoing → ended, when a call is
/// in effect at all, and what the model keeps (no caller outside the live context, no log).
@Suite("App call context: ringing, ongoing, ended")
@MainActor
struct AppCallContextTests {
    @Test("A ringing app call shows the app, the caller and its controls at once")
    func ringing() throws {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ringing(mode: .tap), envelopeTs: 100)
        let call = try #require(controller.call)
        #expect(call.phase == .ringing && call.callId == AppCallSamples.callId)
        #expect(call.appName == "Telegram" && call.caller == .name("Nguyễn Văn A"))
        #expect(call.controls == AppCallControls(answer: true, decline: true) && call.data.answerMode == .tap)
        #expect(call.pairId == CallSamples.pairId && !call.ignored && call.command == nil && call.problem == nil)
    }

    @Test("A call without a caller name (or an empty one) reads as an unknown caller")
    func unknownCaller() {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ringing(caller: nil), envelopeTs: 100)
        #expect(controller.call?.caller == .unknownCaller)
        controller.apply(AppCallSamples.ringing(caller: ""), envelopeTs: 200)
        #expect(controller.call?.caller == .unknownCaller)
    }

    @Test("ringing → ongoing → ended keeps one call; the in-call timer runs from answered_at; ended closes the panel at once")
    func transitions() {
        let clock = TestClock()
        let controller = AppCallController.connectedForTest(clock: clock)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(controller.call?.elapsedSeconds(nowMs: clock.now) == 0)
        controller.apply(AppCallSamples.ongoing(), envelopeTs: AppCallSamples.startedAt + 5000)
        #expect(controller.call?.phase == .inCall && controller.call?.controls == AppCallControls(end: true))
        clock.now += 7000
        #expect(controller.call?.elapsedSeconds(nowMs: clock.now) == 7)
        controller.apply(AppCallSamples.ended(reason: .ended, answeredAt: AppCallSamples.startedAt + 5000),
                         envelopeTs: AppCallSamples.startedAt + 30_000)
        #expect(controller.call == nil) // no "Call ended" panel for an app call
    }

    @Test("A ringing call that ends unanswered closes at once, whatever the reason")
    func endedWithoutAnswer() {
        for reason in [AppCallEndReason.declined, .missed, .unknown] {
            let controller = AppCallController.connectedForTest()
            controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
            controller.apply(AppCallSamples.ended(reason: reason), envelopeTs: 200)
            #expect(controller.call == nil, "\(reason)")
        }
    }

    @Test("Latest wins per call_id: an older envelope is ignored, a later one replaces the data")
    func ordering() {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 300)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 200)
        #expect(controller.call?.phase == .inCall && controller.call?.envelopeTs == 300)
        controller.apply(AppCallSamples.ongoing(caller: "B"), envelopeTs: 400)
        #expect(controller.call?.caller == .name("B") && controller.call?.envelopeTs == 400)
    }

    @Test("A late version of a call that ended is ignored; the call never comes back")
    func lateVersionAfterEnd() {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        controller.apply(AppCallSamples.ended(reason: .missed), envelopeTs: 300)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 200) // reordered by the relay
        #expect(controller.call == nil)
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 400)
        #expect(controller.call == nil)
    }

    @Test("An ended call heard of for the first time shows nothing")
    func endedFirst() {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ended(reason: .ended, answeredAt: AppCallSamples.startedAt + 5000),
                         envelopeTs: 100)
        #expect(controller.call == nil)
    }

    @Test("Two calls at once: the ringing one is shown, the ongoing one comes back when it is over")
    func twoCalls() {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 100)
        controller.apply(AppCallSamples.ringing(AppCallSamples.otherCallId), envelopeTs: 200)
        #expect(controller.call?.callId == AppCallSamples.otherCallId && controller.call?.phase == .ringing)
        controller.apply(AppCallSamples.ended(AppCallSamples.otherCallId, reason: .declined), envelopeTs: 300)
        #expect(controller.call?.callId == AppCallSamples.callId && controller.call?.phase == .inCall)
    }

    @Test("Ignore hides a ringing call; the call stays and shows again when it moves on")
    func ignore() {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        controller.ignore(callId: AppCallSamples.callId)
        #expect(controller.call?.ignored == true)
        controller.apply(AppCallSamples.ringing(caller: "B"), envelopeTs: 150) // same phase: stays ignored
        #expect(controller.call?.ignored == true)
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 200) // answered on the phone
        #expect(controller.call?.ignored == false && controller.call?.phase == .inCall)
        controller.ignore(callId: AppCallSamples.callId) // only a ringing call can be ignored
        #expect(controller.call?.ignored == false)
    }

    @Test("Ignore hides the call_id it names only: another ringing call, or one that is gone, stays as it is")
    func ignoreByCallId() {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        controller.ignore(callId: AppCallSamples.otherCallId) // no such call: nothing changes
        #expect(controller.call?.callId == AppCallSamples.callId && controller.call?.ignored == false)
        controller.apply(AppCallSamples.ringing(AppCallSamples.otherCallId), envelopeTs: 200)
        controller.ignore(callId: AppCallSamples.callId) // the older ringing call, not the one shown
        #expect(controller.call?.callId == AppCallSamples.otherCallId && controller.call?.ignored == false)
        controller.apply(AppCallSamples.ended(AppCallSamples.otherCallId, reason: .missed), envelopeTs: 300)
        #expect(controller.call?.callId == AppCallSamples.callId && controller.call?.ignored == true)
    }

    // MARK: - In effect

    @Test("In effect needs both sides: the phone's app_calls and this device's setting and calls switch")
    func inEffect() {
        let off = AppCallController.connectedForTest(capability: AppCallSamples.capability(appCalls: false))
        off.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(!off.appCallsInEffect && off.call == nil)
        let legacy = AppCallController.connectedForTest(capability: AppCallSamples.capability(appCalls: nil))
        legacy.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(!legacy.appCallsInEffect && legacy.call == nil) // a phone build without CALL-05
        let here = AppCallController.connectedForTest()
        here.enabledHere = { false }
        here.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(!here.appCallsInEffect && here.call == nil)
    }

    @Test("The call goes when the phone turns app calls off, when it is turned off here, and when the pair changes")
    func goesWhenOff() {
        let controller = AppCallController.connectedForTest()
        var enabled = true
        controller.enabledHere = { enabled }
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        #expect(controller.call != nil)
        controller.capabilityUpdated(AppCallSamples.capability(appCalls: false))
        #expect(controller.call == nil)
        controller.capabilityUpdated(AppCallSamples.capability())
        controller.apply(AppCallSamples.ringing(), envelopeTs: 200)
        enabled = false
        controller.settingChanged()
        #expect(controller.call == nil)
        enabled = true
        controller.apply(AppCallSamples.ringing(AppCallSamples.otherCallId), envelopeTs: 300)
        controller.setPair("another-pair")
        #expect(controller.call == nil)
    }

    // MARK: - Envelopes

    @Test("Only call_event/app_call is read: other ops and other types leave the call alone")
    func envelopes() throws {
        let controller = AppCallController.connectedForTest()
        try controller.receive(AppCallSamples.envelope(AppCallSamples.ringing(), ts: 100))
        #expect(controller.call?.phase == .ringing && controller.call?.envelopeTs == 100)
        try controller.receive(AppCallSamples.envelope(AppCallSamples.ongoing(), ts: 200, op: "state"))
        #expect(controller.call?.phase == .ringing)
        controller.receive(IncomingEnvelope(id: HLUUID.v7(), type: .sms, ts: 300,
                                            body: .json(Payload(op: "app_call", data: .emptyObject))))
        controller.receive(IncomingEnvelope(id: HLUUID.v7(), type: .callEvent, ts: 300,
                                            body: .json(Payload(op: "app_call", data: .object(["state": .string("x")])))))
        #expect(controller.call?.phase == .ringing) // malformed data is dropped, never a crash
        try controller.receive(AppCallSamples.envelope(AppCallSamples.ongoing(), ts: 400))
        #expect(controller.call?.phase == .inCall)
    }

    // MARK: - Connection

    @Test("After a reconnect a call the phone does not send again is over; the one it sends again stays")
    func staleAfterReconnect() async {
        let clock = TestClock()
        let controller = AppCallController.connectedForTest(clock: clock)
        controller.apply(AppCallSamples.ringing(), envelopeTs: 100)
        controller.apply(AppCallSamples.ongoing(AppCallSamples.otherCallId), envelopeTs: 100)
        clock.now += 1000
        controller.disconnected()
        controller.connected(peer: FakeCallPeer(), capability: AppCallSamples.capability())
        clock.now += 5
        controller.apply(AppCallSamples.ringing(), envelopeTs: 200) // sent again after the capability exchange
        #expect(await eventually { controller.contexts.keys.sorted() == [AppCallSamples.callId] })
        #expect(controller.call?.callId == AppCallSamples.callId && controller.call?.phase == .ringing)
    }

    @Test("A reconnect with nothing sent again closes the call; a reconnect without calls does nothing")
    func staleAll() async {
        let clock = TestClock()
        let controller = AppCallController.connectedForTest(clock: clock)
        controller.connected(peer: FakeCallPeer(), capability: AppCallSamples.capability())
        #expect(controller.call == nil)
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 100)
        clock.now += 1000
        controller.connected(peer: FakeCallPeer(), capability: AppCallSamples.capability())
        #expect(await eventually { controller.call == nil })
    }

    @Test("Lost connection shows after a moment and clears when the session is back; the call stays")
    func connectionLost() async {
        let controller = AppCallController.connectedForTest()
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 100)
        controller.disconnected()
        #expect(controller.call?.connectionLost == false)
        #expect(await eventually { controller.call?.connectionLost == true })
        controller.connected(peer: FakeCallPeer(), capability: AppCallSamples.capability())
        controller.apply(AppCallSamples.ongoing(), envelopeTs: 200) // the phone sends it again
        #expect(controller.call?.connectionLost == false && controller.call?.phase == .inCall)
    }
}
