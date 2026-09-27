import Foundation
import HLAppCore
import HLProtocol

extension DemoScenario {
    /// Ring → the Mac sees `ringing` → the Mac answers → the modem's call is active → the Mac ends it → `idle`.
    func answerAndEnd() async -> [Step] {
        let start = link.log.count
        let dialed = ContinuousClock.now
        guard (try? await phone.console("gsm call \(DemoNumber.ring)")) != nil else {
            return [record(false, "ring", "the emulator refused `gsm call`")]
        }
        guard let ringing = await nextState(from: start, { $0.state == .ringing && $0.direction == .incoming })
        else { return [record(false, "ring", "no ringing state reached the Mac")] }
        let callId = ringing.value.callId
        var steps = [record(true, "ring → the Mac sees ringing",
                            "call \(DevLink.short(callId)), " + timing(ringing.entry, since: dialed,
                                                                         envelopeTs: envelopeTs(ringing.entry)))]
        let active = CallCheck(name: "the Mac answers", expect: .offhook,
                               modem: { $0.contains { $0.contains(DemoNumber.ring) && $0.contains("active") } },
                               modemText: "gsm list shows the call active")
        steps.append(await command(.answer(.phone), callId: callId, check: active))
        try? await Task.sleep(for: .seconds(2))
        let ended = CallCheck(name: "the Mac ends the call", expect: .idle, modem: { $0.isEmpty },
                              modemText: "gsm list shows no call")
        steps.append(await command(.end, callId: callId, check: ended))
        return steps
    }

    /// A second call that the Mac declines: `idle` with `end_reason = rejected`, no call left on the modem.
    func declineSecondCall() async -> Step {
        let start = link.log.count
        guard (try? await phone.console("gsm call \(DemoNumber.decline)")) != nil,
              let ringing = await nextState(from: start, { $0.state == .ringing })
        else { return record(false, "a second call the Mac declines", "no ringing state") }
        try? await Task.sleep(for: .seconds(2))
        let declined = CallCheck(name: "a second call the Mac declines", expect: .idle, endReason: .rejected,
                                 modem: { $0.isEmpty }, modemText: "gsm list shows no call")
        return await command(.reject(reply: nil), callId: ringing.value.callId, check: declined)
    }

    /// A call nobody answers: the caller hangs up, `idle` with `end_reason = missed`, then `log_new` of the missed entry.
    func missedCall() async -> Step {
        let name = "a missed call → log_new"
        let start = link.log.count
        guard (try? await phone.console("gsm call \(DemoNumber.missed)")) != nil,
              let ringing = await nextState(from: start, { $0.state == .ringing })
        else { return record(false, name, "no ringing state") }
        try? await Task.sleep(for: .seconds(3))
        let hungUp = ContinuousClock.now
        let afterRing = link.log.count
        _ = try? await phone.console("gsm cancel \(DemoNumber.missed)")
        let idle = await nextState(from: afterRing) { $0.callId == ringing.value.callId && $0.state == .idle }
        let logged = await link.log.wait(from: afterRing, timeout: .seconds(10)) { event -> CallLogNewData? in
            if case .logNew(let new, _) = event, new.entry.type == .missed { return new }
            return nil
        }
        guard let idle, let logged else {
            return record(false, name, "idle \(idle.map { $0.value.endReason?.rawValue ?? "?" } ?? "missing"), "
                + "log_new \(logged == nil ? "missing" : "received")")
        }
        let reason = idle.value.endReason
        let matched = logged.value.callId == ringing.value.callId
        return record(reason == .missed, name, "idle end_reason \(reason?.rawValue ?? "none"); log_new entry "
            + "\(logged.value.entry.entryId) \(matched ? "matched to the call" : "without the call_id"), "
            + timing(logged.entry, since: hungUp, envelopeTs: envelopeTs(logged.entry)))
    }

    /// What a call command must lead to: the state, its end reason, and the emulator's modem.
    struct CallCheck {
        let name: String
        let expect: CallPhoneState
        var endReason: CallEndReason?
        let modem: ([String]) -> Bool
        let modemText: String
    }

    /// Sends `command` through the call controller and checks the resulting state and the modem.
    func command(_ command: CallCommand, callId: String, check: CallCheck) async -> Step {
        let start = link.log.count
        let clicked = ContinuousClock.now
        let outcome = await link.calls.perform(command, from: .menu)
        guard outcome == .accepted else { return record(false, check.name, "the phone refused: \(outcome)") }
        guard let state = await nextState(from: start, { $0.callId == callId && $0.state == check.expect }) else {
            return record(false, check.name, "ack ok but no \(check.expect.rawValue) state")
        }
        if let reason = check.endReason, state.value.endReason != reason {
            return record(false, check.name,
                          "end_reason \(state.value.endReason?.rawValue ?? "none"), not \(reason.rawValue)")
        }
        let calls = await modemCalls()
        let modemOK = check.modem(calls)
        let timingText = timing(state.entry, since: clicked, envelopeTs: envelopeTs(state.entry))
        return record(modemOK, check.name, "\(check.expect.rawValue) \(timingText); "
            + (modemOK ? check.modemText : "gsm list: \(calls.map(DevConsole.number))"))
    }

    func envelopeTs(_ entry: DevEventLog.Entry) -> Int64 {
        switch entry.event {
        case .callState(_, let ts), .logNew(_, let ts), .smsNew(_, let ts), .smsStatus(_, let ts): ts
        default: entry.wallMs
        }
    }
}
