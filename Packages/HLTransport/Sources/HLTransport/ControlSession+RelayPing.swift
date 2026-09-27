import Foundation
import HLProtocol

extension ControlSession {
    /// Over the relay the WebSocket ping only reaches the relay, so every `relayPingInterval` a `ping/ping` must be
    /// acknowledged within `PONG_TIMEOUT`, or the session counts as lost (CONN-02 steps 1 and 3, API 2).
    func endToEndPingLoop() async {
        var seq: Int64 = 0
        while ending == nil {
            do {
                try await Task.sleep(for: configuration.relayPingInterval)
            } catch {
                return
            }
            seq += 1
            guard await pingEndToEnd(seq: seq, timeout: configuration.pongTimeout) else {
                await end(.pongTimeout, closing: .normal)
                return
            }
        }
    }

    /// One `ping/ping` now; `false` when no `ack` came in time. Used when `presence` says the phone went offline, a
    /// hint the session checks instead of trusting (CONN-03 API 5).
    public func probeEndToEnd(timeout: Duration) async -> Bool {
        guard ending == nil else { return false }
        let alive = await pingEndToEnd(seq: Int64(HLUUID.currentTimeMs()), timeout: timeout)
        if !alive { await end(.pongTimeout, closing: .normal) }
        return alive
    }

    private func pingEndToEnd(seq: Int64, timeout: Duration) async -> Bool {
        let started = ContinuousClock.now
        guard let ack = try? await request(.ping, op: "ping", data: PingData(seq: seq), timeout: timeout), ack.ok
        else { return false }
        endToEndRoundTrip = ContinuousClock.now - started
        return true
    }
}
