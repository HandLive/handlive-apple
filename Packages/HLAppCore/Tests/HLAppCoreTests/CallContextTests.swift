import Foundation
import HLProtocol
import HLTransport
import Testing
@testable import HLAppCore

/// CALL-01 API 1 logic 6 on the client: which version of the phone's call is shown, when it closes, and the missed
/// calls of flow A.
@Suite("Call context: ringing, in call, ended")
@MainActor
struct CallContextTests {
    @Test("A ringing state shows the call; the number that arrives later updates the same call (E10)")
    func ringingThenNumber() {
        let controller = CallController.connectedForTest()
        controller.apply(CallSamples.ringing(number: nil, name: nil, presentation: .unknown), envelopeTs: 100)
        #expect(controller.call?.phase == .ringing && controller.call?.caller == .unknownCaller)
        controller.apply(CallSamples.ringing(), envelopeTs: 200)
        #expect(controller.call?.caller == .name("Nguyễn Văn A") && controller.call?.envelopeTs == 200)
    }

    @Test("An older envelope is ignored; an ended call only takes the idle correction")
    func ordering() async {
        let controller = CallController.connectedForTest()
        controller.apply(CallSamples.offhook(), envelopeTs: 300)
        controller.apply(CallSamples.ringing(), envelopeTs: 200)
        #expect(controller.call?.phase == .inCall)
        controller.apply(CallSamples.idle(reason: .ended, answeredAt: CallSamples.startedAt + 5000), envelopeTs: 400)
        #expect(controller.call?.phase == .ended)
        controller.apply(CallSamples.offhook(), envelopeTs: 500)
        #expect(controller.call?.phase == .ended)
        controller.apply(CallSamples.idle(reason: .answeredElsewhere, answeredAt: CallSamples.startedAt + 5000),
                         envelopeTs: 600)
        #expect(controller.call?.state.endReason == .answeredElsewhere)
        #expect(await eventually { controller.call == nil }) // "Call ended" for a moment, then closed
        controller.apply(CallSamples.ringing(), envelopeTs: 700) // a late version of the call that ended
        #expect(controller.call == nil)
    }

    @Test("A new call_id in ringing replaces the old context whose idle was lost")
    func newCallReplaces() {
        let controller = CallController.connectedForTest()
        controller.apply(CallSamples.offhook(), envelopeTs: 100)
        controller.apply(CallSamples.ringing(CallSamples.otherCallId), envelopeTs: 900)
        #expect(controller.call?.callId == CallSamples.otherCallId && controller.call?.phase == .ringing)
        controller.apply(CallSamples.offhook(), envelopeTs: 950) // the old call never comes back
        #expect(controller.call?.callId == CallSamples.otherCallId)
    }

    @Test("A ringing call that ends closes at once; flow A reports it missed, with the call log it does not")
    func missed() {
        let flowA = CallController.connectedForTest(capability: CallSamples.capability(callLog: false))
        let events = CallEventLog(flowA)
        flowA.apply(CallSamples.ringing(number: nil, name: nil, presentation: .unknown), envelopeTs: 100)
        flowA.apply(CallSamples.idle(reason: .missed, number: nil), envelopeTs: 200)
        #expect(flowA.call == nil)
        #expect(events.events == [.missed(MissedCall(
            pairId: CallSamples.pairId, entryId: nil, callId: CallSamples.callId, number: nil, caller: .unknownCaller,
            ts: CallSamples.startedAt, subId: 1, simLabel: "SIM 1"))])

        let withLog = CallController.connectedForTest(capability: CallSamples.capability(callLog: true))
        let logEvents = CallEventLog(withLog)
        withLog.apply(CallSamples.ringing(), envelopeTs: 100)
        withLog.apply(CallSamples.idle(reason: .missed), envelopeTs: 200)
        #expect(withLog.call == nil && logEvents.events.isEmpty)
        let missingLog = CallController.connectedForTest(
            capability: CallSamples.capability(callLog: true, missing: ["android.permission.READ_CALL_LOG"]))
        #expect(!missingLog.callLogAvailable)
    }

    @Test("A call in progress shows Call ended for a moment, then closes")
    func endedDisplay() async {
        let controller = CallController.connectedForTest()
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        controller.apply(CallSamples.offhook(), envelopeTs: 200)
        #expect(controller.call?.phase == .inCall)
        controller.apply(CallSamples.idle(reason: .ended, answeredAt: CallSamples.startedAt + 5000), envelopeTs: 300)
        #expect(controller.call?.phase == .ended)
        #expect(controller.call?.elapsedSeconds(nowMs: 0) == 20)
        #expect(await eventually { controller.call == nil })
    }

    @Test("Call waiting is shown as such, with the waiting caller")
    func waiting() {
        let controller = CallController.connectedForTest()
        controller.apply(CallSamples.offhook(), envelopeTs: 100)
        controller.apply(CallSamples.waiting(), envelopeTs: 200)
        #expect(controller.call?.phase == .waiting)
        #expect(controller.call?.waitingCaller == .number("+84900000456"))
    }

    @Test("Timer: envelope ts minus answered_at, plus the time since the envelope arrived here")
    func timer() {
        let clock = TestClock()
        let controller = CallController.connectedForTest(clock: clock)
        clock.now = 10_000
        controller.apply(CallSamples.offhook(answeredAt: CallSamples.startedAt + 5000),
                         envelopeTs: CallSamples.startedAt + 65_000)
        #expect(controller.call?.elapsedSeconds(nowMs: 10_000) == 60)
        #expect(controller.call?.elapsedSeconds(nowMs: 25_500) == 75)
    }

    @Test("Callers: withheld, unknown, outgoing, and a call log entry without a number")
    func callers() {
        #expect(CallerIdentity(state: CallSamples.ringing(number: nil, name: nil, presentation: .restricted))
            == .noCallerId)
        #expect(CallerIdentity(state: CallSamples.ringing(number: nil, name: nil, presentation: .unknown))
            == .unknownCaller)
        #expect(CallerIdentity(state: CallSamples.ringing(name: nil)) == .number("+84900000123"))
        let outgoing = CallStateData(callId: CallSamples.callId, direction: .outgoing, state: .offhook, number: nil,
                                     displayName: nil, presentation: .unknown, startedAt: 1, controls: .none)
        #expect(CallerIdentity(state: outgoing) == .outgoingCall)
        #expect(CallerIdentity(entry: CallLogEntryData(entryId: 1, number: nil, displayName: nil, type: .missed, ts: 1,
                                                       durationS: 0, subId: nil)) == .noCallerId)
    }

    @Test("Reconnecting: a call the phone does not send again is over; one it sends stays")
    func reconnect() async {
        let peer = FakeCallPeer()
        let clock = TestClock()
        let controller = CallController.connectedForTest(peer: peer, clock: clock)
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        controller.disconnected()
        #expect(await eventually { controller.call?.connectionLost == true })
        clock.now += 1000
        controller.connected(peer: peer, capability: CallSamples.capability())
        #expect(controller.call?.connectionLost == false)
        clock.now += 10
        controller.apply(CallSamples.ringing(), envelopeTs: 150) // E8: the phone sends the current state
        try? await Task.sleep(for: .milliseconds(300))
        #expect(controller.call != nil)
        controller.disconnected()
        clock.now += 1000
        controller.connected(peer: peer, capability: CallSamples.capability())
        #expect(await eventually { controller.call == nil })
    }

    @Test("Lost connection shows only after the session has been gone for the delay, and hides once it is back")
    func connectionLostNoticeWaits() async throws {
        let peer = FakeCallPeer()
        let controller = CallController.connectedForTest(peer: peer)
        controller.apply(CallSamples.offhook(answeredAt: CallSamples.startedAt + 5000), envelopeTs: 100)
        controller.disconnected()
        #expect(controller.call?.connectionLost == false) // CALL-03 E6: nothing right away
        try await Task.sleep(for: .milliseconds(60))
        controller.connected(peer: peer, capability: CallSamples.capability()) // a quick reconnect
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.call?.connectionLost == false)
        controller.apply(CallSamples.offhook(answeredAt: CallSamples.startedAt + 5000), envelopeTs: 200)
        controller.disconnected()
        #expect(await eventually { controller.call?.connectionLost == true })
        controller.connected(peer: peer, capability: CallSamples.capability())
        #expect(controller.call?.connectionLost == false)
    }

    @Test("Calls off on either side, or the phone's state permission missing: nothing is shown")
    func notInEffect() {
        let controller = CallController.connectedForTest()
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        controller.capabilityUpdated(CallSamples.capability(enabled: false))
        #expect(controller.call == nil && !controller.callsInEffect)
        let noState = CallController.connectedForTest(capability: CallSamples.capability(missing: ["READ_PHONE_STATE"]))
        #expect(!noState.callsInEffect)
        let off = CallController.connectedForTest()
        var enabled = true
        off.enabledHere = { enabled }
        off.apply(CallSamples.ringing(), envelopeTs: 100)
        enabled = false
        off.settingChanged()
        #expect(off.call == nil)
        off.apply(CallSamples.ringing(CallSamples.otherCallId), envelopeTs: 200)
        #expect(off.call == nil)
    }

    @Test("Ignore hides the panel until the call changes or its notification is clicked")
    func ignore() {
        let controller = CallController.connectedForTest()
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        controller.ignore()
        #expect(controller.call?.ignored == true)
        controller.showAgain()
        #expect(controller.call?.ignored == false)
        controller.ignore()
        controller.apply(CallSamples.offhook(), envelopeTs: 200)
        #expect(controller.call?.ignored == false && controller.call?.phase == .inCall)
    }

    @Test("A state from an envelope that is not call_event/state changes nothing")
    func otherOps() {
        let controller = CallController.connectedForTest()
        let payload = Payload(op: "log_new", data: .emptyObject)
        controller.receive(IncomingEnvelope(id: HLUUID.v7(), type: .callEvent, ts: 1, body: .json(payload)))
        #expect(controller.call == nil)
        let state = Payload(op: "state", data: (try? HLJSON.convert(from: CallSamples.ringing())) ?? .emptyObject)
        controller.receive(IncomingEnvelope(id: HLUUID.v7(), type: .callEvent, ts: 5, body: .json(state)))
        #expect(controller.call?.envelopeTs == 5)
    }

    @Test("In the background the call is forgotten until the phone reports it again; ended calls stay dropped")
    func forgetCall() {
        let controller = CallController.connectedForTest()
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        controller.apply(CallSamples.idle(reason: .missed), envelopeTs: 200)
        controller.apply(CallSamples.ringing(CallSamples.otherCallId), envelopeTs: 300)
        controller.forgetCall()
        #expect(controller.call == nil)
        controller.apply(CallSamples.ringing(), envelopeTs: 150) // a late version of the ended call
        #expect(controller.call == nil)
        controller.apply(CallSamples.ringing(CallSamples.otherCallId), envelopeTs: 400)
        #expect(controller.call?.callId == CallSamples.otherCallId)
    }

    @Test("Call permissions: the call log and answering always, phone state and contacts while calls are on")
    func callPermissions() {
        #expect(CallPermissions.isCall("android.permission.READ_CALL_LOG", callsOnPhone: false))
        #expect(CallPermissions.isCall("ANSWER_PHONE_CALLS", callsOnPhone: false))
        #expect(!CallPermissions.isCall("READ_PHONE_STATE", callsOnPhone: false))
        #expect(CallPermissions.isCall("READ_CONTACTS", callsOnPhone: true))
        #expect(!CallPermissions.isCall("CAMERA", callsOnPhone: true))
    }
}
