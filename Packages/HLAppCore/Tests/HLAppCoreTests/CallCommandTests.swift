import Foundation
import HLProtocol
import HLTransport
import Testing
@testable import HLAppCore

/// CALL-02 and CALL-03 over WebSocket: Answer, Decline, Decline with Message and End, with the E5 rule.
@Suite("Call commands: answer, decline, end")
@MainActor
struct CallCommandTests {
    @Test("Answer: one call_event/action with audio phone, buttons locked until the offhook state")
    func answer() async throws {
        let peer = FakeCallPeer([.ok])
        let controller = CallController.connectedForTest(peer: peer)
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        let outcome = await controller.perform(.answer(.phone))
        #expect(outcome == .accepted)
        #expect(peer.sent.count == 1 && peer.sent[0].op == .action)
        #expect(peer.sent[0].data == .object(["call_id": .string(CallSamples.callId), "action": .string("answer"),
                                               "audio": .string("phone")]))
        #expect(controller.call?.command == .answer(.phone) && !controller.allows(.reject(reply: nil)))
        controller.apply(CallSamples.offhook(), envelopeTs: 200)
        #expect(controller.call?.command == nil && controller.call?.phase == .inCall)
    }

    @Test("A successful ack without a new state unlocks the buttons after a moment (step 7)")
    func ackWithoutState() async {
        let controller = CallController.connectedForTest(peer: FakeCallPeer([.ok]))
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.reject(reply: nil)) == .accepted)
        #expect(await eventually { controller.call?.command == nil })
        #expect(controller.call?.problem == nil)
    }

    @Test("E5: no ack in time → back to how it was, Couldn't send; the command is never sent again with a new id")
    func noAck() async {
        let peer = FakeCallPeer()
        let controller = CallController.connectedForTest(peer: peer)
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.answer(.phone)) == .failed(.commandNotSent))
        #expect(controller.call?.problem == .commandNotSent && controller.call?.command == nil)
        #expect(peer.sent.count == 1)
    }

    @Test("A session lost while waiting: the same envelope id goes again once the session is back in time")
    func resendAfterReconnect() async {
        let lost = FakeCallPeer(otherwise: .sessionEnded) // a dead session keeps failing
        let controller = CallController.connectedForTest(peer: lost)
        controller.requestTimeout = .seconds(3)
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        let back = FakeCallPeer([.ok])
        let reconnect = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            controller.disconnected()
            try? await Task.sleep(for: .milliseconds(50))
            controller.connected(peer: back, capability: CallSamples.capability())
        }
        #expect(await controller.perform(.reject(reply: nil)) == .accepted)
        await reconnect.value
        #expect(back.sent.count == 1 && !lost.sent.isEmpty)
        #expect(Set((lost.sent + back.sent).map(\.id)).count == 1)
    }

    @Test("Refusals map to the panel's problems (CALL-02 E1–E4, CALL-03 E9)")
    func refusals() async {
        struct Refusal {
            let error: AckError
            let command: CallCommand
            let problem: CallProblem
        }
        let cases = [
            Refusal(error: CallSamples.refused(.callNotFound), command: .reject(reply: nil), problem: .callEnded),
            Refusal(error: CallSamples.refused(.callActionNotAllowed, state: .offhook, reason: .state),
                    command: .answer(.phone), problem: .answeredOnPhone),
            Refusal(error: CallSamples.refused(.callActionNotAllowed, state: .idle, reason: .state),
                    command: .reject(reply: nil), problem: .callEnded),
            Refusal(error: CallSamples.refused(.permissionMissing), command: .answer(.phone),
                    problem: .answerPermissionMissing),
            Refusal(error: CallSamples.refused(.featureDisabled), command: .reject(reply: nil),
                    problem: .featureOffOnPhone),
            Refusal(error: CallSamples.refused(.callActionNotAllowed, state: .offhook, reason: .system), command: .end,
                    problem: .endOnPhone),
            Refusal(error: CallSamples.refused(.internal), command: .end, problem: .commandNotSent),
        ]
        for refusal in cases {
            #expect(CallProblem(error: refusal.error, command: refusal.command) == refusal.problem)
        }
        let controller = CallController.connectedForTest(peer: FakeCallPeer([.refused(cases[1].error)]))
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.answer(.phone)) == .failed(.answeredOnPhone))
        #expect(controller.call?.problem == .answeredOnPhone && controller.call?.command == nil)
    }

    @Test("End goes out while in call; nothing is allowed that controls do not allow")
    func endAndControls() async {
        let peer = FakeCallPeer([.ok])
        let controller = CallController.connectedForTest(peer: peer)
        #expect(await controller.perform(.end) == .notAllowed)
        controller.apply(CallSamples.offhook(), envelopeTs: 100)
        #expect(!controller.allows(.answer(.phone)) && !controller.allows(.reject(reply: nil)))
        #expect(await controller.perform(.end) == .accepted)
        #expect(peer.sent.map(\.data) == [.object(["call_id": .string(CallSamples.callId), "action": .string("end")])])
        controller.apply(CallSamples.ringing(CallSamples.otherCallId, number: nil, name: nil, presentation: .restricted),
                         envelopeTs: 200)
        #expect(!controller.allows(.reject(reply: "x"))) // no number to send a quick reply to
    }
}

/// CALL-02 flow B: "Decline" from the iPhone/iPad notification, with or without the call on screen.
@Suite("Decline from a notification")
@MainActor
struct CallNotificationDeclineTests {
    @Test("Sent for the notification's call once a session exists, within the deadline")
    func sentWhenConnected() async {
        let controller = CallController(now: { 0 })
        controller.setPair(CallSamples.pairId, capability: CallSamples.capability())
        let peer = FakeCallPeer([.ok])
        let connect = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            controller.connected(peer: peer, capability: CallSamples.capability())
        }
        let outcome = await controller.declineFromNotification(callId: CallSamples.callId, within: .seconds(3))
        await connect.value
        #expect(outcome == .accepted)
        #expect(peer.sent.map(\.data) == [.object(["call_id": .string(CallSamples.callId), "action": .string("reject")])])
    }

    @Test("No session in time: not sent; the call already over: the phone says so")
    func failures() async {
        let controller = CallController(now: { 0 })
        controller.setPair(CallSamples.pairId, capability: CallSamples.capability())
        #expect(await controller.declineFromNotification(callId: CallSamples.callId, within: .milliseconds(200))
            == .failed(.commandNotSent))
        controller.connected(peer: FakeCallPeer([.refused(CallSamples.refused(.callNotFound))]),
                             capability: CallSamples.capability())
        #expect(await controller.declineFromNotification(callId: CallSamples.callId, within: .seconds(2))
            == .failed(.callEnded))
    }

    @Test("Any refusal because the call moved on means the notification can go; other errors are failures")
    func refusals() async {
        let controller = CallController(now: { 0 })
        controller.setPair(CallSamples.pairId, capability: CallSamples.capability())
        controller.connected(peer: FakeCallPeer([
            .refused(CallSamples.refused(.callActionNotAllowed, state: .ringing, reason: .system)),
            .refused(CallSamples.refused(.callActionNotAllowed, state: .idle, reason: .state)),
            .refused(CallSamples.refused(.permissionMissing)),
        ]), capability: CallSamples.capability())
        #expect(await controller.declineFromNotification(callId: CallSamples.callId, within: .seconds(2))
            == .failed(.answeredOnPhone))
        #expect(await controller.declineFromNotification(callId: CallSamples.callId, within: .seconds(2))
            == .failed(.callEnded))
        #expect(await controller.declineFromNotification(callId: CallSamples.callId, within: .seconds(2))
            == .failed(.answerPermissionMissing))
    }
}

/// CALL-02 API 5: the quick reply of "Decline with Message…" and E9.
@Suite("Decline with a message")
@MainActor
struct CallQuickReplyTests {
    @Test("The decline's successful ack sends the reply to the caller through the call's SIM")
    func sentOnAck() async {
        let controller = CallController.connectedForTest(peer: FakeCallPeer([.ok]))
        let events = CallEventLog(controller)
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        #expect(await controller.perform(.reject(reply: "I'm in a meeting")) == .accepted)
        #expect(events.events == [.sendReply(pairId: CallSamples.pairId, number: "+84900000123", subId: 1,
                                             body: "I'm in a meeting")])
        controller.apply(CallSamples.idle(reason: .rejected), envelopeTs: 200)
        #expect(events.events.count == 1)
    }

    @Test("No ack, but the idle state arrives: the reply goes then")
    func sentOnIdle() async {
        let controller = CallController.connectedForTest(peer: FakeCallPeer())
        let events = CallEventLog(controller)
        controller.apply(CallSamples.ringing(), envelopeTs: 100)
        let decline = Task { await controller.perform(.reject(reply: "Later")) }
        #expect(await eventually { controller.call?.command != nil })
        controller.apply(CallSamples.idle(reason: .rejected), envelopeTs: 200)
        _ = await decline.value
        #expect(events.events.count == 1)
    }

    @Test("E9: the call was answered first — the message is not sent")
    func answeredFirst() async {
        let refused = CallController.connectedForTest(peer: FakeCallPeer([.refused(
            CallSamples.refused(.callActionNotAllowed, state: .offhook, reason: .state))]))
        let events = CallEventLog(refused)
        refused.apply(CallSamples.ringing(), envelopeTs: 100)
        #expect(await refused.perform(.reject(reply: "Later")) == .failed(.messageNotSent))
        #expect(events.events.isEmpty)

        let answered = CallController.connectedForTest(peer: FakeCallPeer())
        let answeredEvents = CallEventLog(answered)
        answered.apply(CallSamples.ringing(), envelopeTs: 100)
        let decline = Task { await answered.perform(.reject(reply: "Later")) }
        #expect(await eventually { answered.call?.command != nil })
        answered.apply(CallSamples.offhook(), envelopeTs: 200)
        #expect(answered.call?.problem == .messageNotSent)
        _ = await decline.value
        #expect(answeredEvents.events.isEmpty)
    }
}
