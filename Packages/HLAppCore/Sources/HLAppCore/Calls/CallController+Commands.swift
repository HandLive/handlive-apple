import Foundation
import HLProtocol
import HLTransport

extension CallController {
    /// How a command ended, for the platform code (a notification action waits for it; the panel reads `call`).
    public enum CommandOutcome: Equatable, Sendable {
        /// The phone called the Telecom method; the result arrives as `state`.
        case accepted
        /// The phone refused it, or no `ack` came in time.
        case failed(CallProblem)
        /// The buttons do not allow it now (no call, another command in progress, `controls` say no).
        case notAllowed
    }

    /// Whether the panel may offer `command` now: `controls` allow it, no other command is waiting, and a quick reply
    /// has a number to go to (CALL-01 fields 6–8).
    public func allows(_ command: CallCommand) -> Bool {
        guard let call, call.command == nil else { return false }
        let controls = call.state.controls
        switch command {
        case .answer: return controls.answer
        case .reject(let reply): return controls.reject && (reply == nil || call.state.number != nil)
        case .end: return controls.end
        }
    }

    /// Sends `command` for the current call as `call_event/action` (CALL-02 step 4, CALL-03 step 6). The buttons stay
    /// locked until an `ack` or a new `state` (CALL-02 special requirements). Without an `ack` within `REQUEST_TIMEOUT`
    /// the panel goes back to how it was with "Couldn't send the command to the phone" (E5); a session lost meanwhile
    /// gets the same envelope `id` again if it comes back in time; no new `id` is ever sent on its own.
    @discardableResult
    public func perform(_ command: CallCommand, from source: CallActionSource = .panel) async -> CommandOutcome {
        guard allows(command), var current = call else { return .notAllowed }
        let callId = current.callId
        BenchLog.event("call_action_tap", ["call": callId, "action": command.action.rawValue, "from": source.rawValue])
        current.command = command
        current.problem = nil
        call = current
        if case .reject(let reply?) = command { pendingReply = (callId, reply) }
        var audio: CallAudioLocation?
        if case .answer(let location) = command { audio = location }
        let request = CallActionRequest(callId: callId, action: command.action, audio: audio)
        guard let ack = await send(request, within: requestTimeout) else {
            finish(callId: callId, problem: .commandNotSent)
            return .failed(.commandNotSent)
        }
        var fields = [("call", callId), ("env", ack.re), ("peer", benchPeer), ("ok", ack.ok ? "true" : "false")]
        if let code = ack.error?.code { fields.append(("code", code.rawValue)) }
        BenchLog.event("call_action_ack_received", fields: fields)
        return ack.ok ? accepted(callId: callId) : refused(ack, command: command, callId: callId)
    }

    private func accepted(callId: String) -> CommandOutcome {
        if let reply = pendingReply, reply.callId == callId, let state = call?.state {
            pendingReply = nil
            sendReply(reply.body, for: state) // API 5 logic 1: on the successful ack of the decline
        }
        waitForState(callId: callId)
        return .accepted
    }

    private func refused(_ ack: Ack, command: CallCommand, callId: String) -> CommandOutcome {
        var problem = ack.error.map { CallProblem(error: $0, command: command) } ?? .commandNotSent
        if pendingReply?.callId == callId {
            pendingReply = nil
            if call?.phase == .inCall || problem == .answeredOnPhone { problem = .messageNotSent }
        }
        finish(callId: callId, problem: problem)
        return .failed(problem)
    }

    /// CALL-02 flow B: "Decline" on the iPhone/iPad notification. The app may have been woken in the background, so
    /// the call need not be on screen: the command goes out for `callId` as soon as a session exists, all within
    /// `deadline` (`CALL_REJECT_BG_TIMEOUT`, 15 s, the background connection included; B2–B3).
    public func declineFromNotification(callId: String, within deadline: Duration) async -> CommandOutcome {
        BenchLog.event("call_action_tap", ["call": callId, "action": CallAction.reject.rawValue, "from": "notification"])
        guard let ack = await send(CallActionRequest(callId: callId, action: .reject), within: deadline) else {
            return .failed(.commandNotSent)
        }
        var fields = [("call", callId), ("env", ack.re), ("peer", benchPeer), ("ok", ack.ok ? "true" : "false")]
        if let code = ack.error?.code { fields.append(("code", code.rawValue)) }
        BenchLog.event("call_action_ack_received", fields: fields)
        guard !ack.ok else { return .accepted }
        return .failed(ack.error.map { CallProblem(error: $0, command: .reject(reply: nil)) } ?? .commandNotSent)
    }

    /// One `ack` wait of `window` from the click; the same envelope `id` whenever a session is there.
    private func send(_ request: CallActionRequest, within window: Duration) async -> Ack? {
        let id = HLUUID.v7()
        let deadline = ContinuousClock.now.advanced(by: window)
        var attempt = 0
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return nil }
            guard let peer else {
                try? await Task.sleep(for: min(.milliseconds(100), remaining))
                continue
            }
            attempt += 1
            BenchLog.event("call_action_sent", ["call": request.callId, "env": id, "peer": benchPeer,
                                                "action": request.action.rawValue,
                                                "via": peer.route == .lan ? "lan" : "relay", "attempt": String(attempt)])
            do {
                return try await peer.request(.action, data: request, id: id, timeout: remaining)
            } catch SessionError.timedOut {
                return nil
            } catch {
                // The session ended while waiting: the same `id` goes again once a session is back (CALL-02 step 4).
                try? await Task.sleep(for: min(.milliseconds(100), remaining))
            }
        }
    }

    /// After a successful `ack`: at most `stateWait` for the `state` that carries the result, then the buttons unlock
    /// and the latest `state` stays on screen (CALL-02 step 7).
    private func waitForState(callId: String) {
        stateWaitTask?.cancel()
        stateWaitTask = Task { [weak self, stateWait] in
            try? await Task.sleep(for: stateWait)
            guard !Task.isCancelled else { return }
            self?.finish(callId: callId, problem: nil)
        }
    }

    private func finish(callId: String, problem: CallProblem?) {
        guard var current = call, current.callId == callId else { return }
        current.command = nil
        if let problem { current.problem = problem }
        call = current
    }
}
