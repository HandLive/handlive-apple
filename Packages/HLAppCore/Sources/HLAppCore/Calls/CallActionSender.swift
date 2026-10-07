import Foundation
import HLProtocol
import HLTransport

/// Sends one `call_event/action` for the call controllers (telephony CALL-02/03 and app calls CALL-05).
@MainActor
enum CallActionSender {
    /// One `ack` wait of `window` from the click; the same envelope `id` whenever a session is there. A session that
    /// ends while waiting gets the same `id` again once a new one is back; without an `ack` in time the result is `nil`
    /// and no new `id` is ever sent on its own (CALL-02 step 4, E5). `clock` times the window and the waits between
    /// attempts.
    static func send(_ request: CallActionRequest, via peer: () -> (any CallPeer)?, benchPeer: String,
                     within window: Duration, clock: any Clock<Duration>) async -> Ack? {
        let id = HLUUID.v7()
        let timeLeft = clock.countdown(from: window)
        var attempt = 0
        while true {
            let remaining = timeLeft()
            guard remaining > .zero else { return nil }
            guard let current = peer() else {
                try? await clock.sleep(for: min(.milliseconds(100), remaining))
                continue
            }
            attempt += 1
            BenchLog.event("call_action_sent", ["call": request.callId, "env": id, "peer": benchPeer,
                                                "action": request.action.rawValue,
                                                "via": current.route == .lan ? "lan" : "relay",
                                                "attempt": String(attempt)])
            do {
                return try await current.request(.action, data: request, id: id, timeout: remaining)
            } catch SessionError.timedOut {
                return nil
            } catch {
                // The session ended while waiting: the same `id` goes again once a session is back (CALL-02 step 4).
                try? await clock.sleep(for: min(.milliseconds(100), remaining))
            }
        }
    }

    /// The `call_action_ack_received` bench line of an `ack` (the phone's reply to a command).
    static func logAck(_ ack: Ack, callId: String, benchPeer: String) {
        var fields = [("call", callId), ("env", ack.re), ("peer", benchPeer), ("ok", ack.ok ? "true" : "false")]
        if let code = ack.error?.code { fields.append(("code", code.rawValue)) }
        BenchLog.event("call_action_ack_received", fields: fields)
    }
}

private extension Clock<Duration> {
    /// The time left of `window` started now, read on this clock (a member, so an `any Clock` can call it).
    func countdown(from window: Duration) -> () -> Duration {
        let deadline = now.advanced(by: window)
        return { now.duration(to: deadline) }
    }
}
