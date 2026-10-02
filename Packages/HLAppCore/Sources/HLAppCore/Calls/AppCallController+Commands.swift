import Foundation
import HLProtocol
import HLTransport

extension AppCallController {
    /// Whether the panel of the live call `callId` may offer `command` now: the phone's `controls` allow it and no other
    /// command is waiting; a call that is gone allows nothing. The audio of an app call stays on the phone, and there is
    /// no SMS reply to an app call.
    public func allows(_ command: CallCommand, for callId: String) -> Bool {
        guard let call = contexts[callId], call.command == nil else { return false }
        let controls = call.controls
        switch command {
        case .answer(let audio): return audio == .phone && call.phase == .ringing && controls.answer
        case .reject(let reply): return reply == nil && call.phase == .ringing && controls.decline
        case .end: return call.phase == .inCall && controls.end
        }
    }

    /// "Ignore" on the panel of the call `callId`: no panel and no ringing here; the phone keeps ringing. Another call,
    /// or one that is gone, stays as it is.
    public func ignore(callId: String) {
        guard contexts[callId]?.phase == .ringing else { return }
        change(callId) { $0.ignored = true }
    }

    /// The problem line was read or the panel changed: it goes away.
    public func clearProblem() {
        guard let current = call, current.problem != nil else { return }
        change(current.callId) { $0.problem = nil }
    }

    /// Sends `command` for the live call `callId` (the one its panel shows) as `call_event/action` keyed by that
    /// `call_id`; a call that is gone gets nothing. The buttons stay locked until an `ack` or a new version. Without an
    /// `ack` within `REQUEST_TIMEOUT` the panel goes back to how it was with "Couldn't send the command to the phone"; a
    /// session lost meanwhile gets the same envelope `id` again if it comes back in time; no new `id` is ever sent on
    /// its own.
    @discardableResult
    public func perform(_ command: CallCommand, for callId: String,
                        from source: CallActionSource = .panel) async -> CallController.CommandOutcome {
        guard allows(command, for: callId) else { return .notAllowed }
        BenchLog.event("call_action_tap", ["call": callId, "action": command.action.rawValue, "from": source.rawValue])
        change(callId) {
            $0.command = command
            $0.problem = nil
        }
        // Answer leaves `audio` out, which means `phone`: the call audio of an app call stays on the phone and the phone
        // refuses `mac` (CALL-05 API 2).
        let request = CallActionRequest(callId: callId, action: command.action)
        guard let ack = await CallActionSender.send(request, via: { [weak self] in self?.peer }, benchPeer: benchPeer,
                                                    within: requestTimeout) else {
            finish(callId, problem: .commandNotSent)
            return .failed(.commandNotSent)
        }
        CallActionSender.logAck(ack, callId: callId, benchPeer: benchPeer)
        return ack.ok ? accepted(callId, command) : refused(ack, command: command, callId: callId)
    }

    private func accepted(_ callId: String, _ command: CallCommand) -> CallController.CommandOutcome {
        if case .answer = command { change(callId) { $0.answerRequested = true } }
        stateWaitTasks[callId]?.cancel()
        stateWaitTasks[callId] = Task { [weak self, stateWait] in
            try? await Task.sleep(for: stateWait)
            guard !Task.isCancelled else { return }
            self?.finish(callId, problem: nil)
        }
        return .accepted
    }

    private func refused(_ ack: Ack, command: CallCommand, callId: String) -> CallController.CommandOutcome {
        guard let error = ack.error else {
            finish(callId, problem: .commandNotSent)
            return .failed(.commandNotSent)
        }
        switch error.code {
        case .callAppActionUnavailable:
            // The app's notification no longer offers that action: the phone's next `app_call` says what is left, and
            // until then the control is withdrawn instead of letting the user press it again.
            change(callId) {
                $0.command = nil
                $0.withdrawn.insert(command.action)
            }
            return .notAllowed
        case .callNotFound:
            // The phone has forgotten the call: the panel closes, and no later version of it is taken (CALL-05 E3).
            if let envelopeTs = contexts[callId]?.envelopeTs { close(callId: callId, envelopeTs: envelopeTs) }
            return .failed(.callEnded)
        case .featureDisabled:
            // App calls are not in effect for this session: every app-call panel of this phone closes (CALL-05 E4).
            clear()
            return .failed(.featureOffOnPhone)
        default:
            let problem = CallProblem(appCallError: error)
            finish(callId, problem: problem)
            return .failed(problem)
        }
    }

    /// The command is over: the buttons unlock, with the problem when there was one.
    func finish(_ callId: String, problem: CallProblem?) {
        change(callId) {
            $0.command = nil
            if let problem { $0.problem = problem }
        }
    }
}
