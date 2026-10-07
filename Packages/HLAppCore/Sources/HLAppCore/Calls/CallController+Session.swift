import Foundation
import HLProtocol

extension CallController {
    // MARK: - Session

    /// A session reached `Connected`. The phone sends the current call right after the capability exchange (CALL-01
    /// E8, logic 3); a call it no longer has gets no `state`, so one not refreshed within `reconnectGrace` goes.
    public func connected(peer: any CallPeer, capability: CapabilityData) {
        self.peer = peer
        connectionLostTask?.cancel()
        connectedAtMs = now()
        capabilityUpdated(capability)
        guard var current = call, current.phase != .ended else { return }
        current.connectionLost = false
        call = current
        let callId = current.callId
        let since = connectedAtMs
        staleTask?.cancel()
        staleTask = Task { [weak self, clock, reconnectGrace] in
            try? await clock.sleep(for: reconnectGrace)
            guard !Task.isCancelled, let self, let call = self.call, call.callId == callId,
                  call.receivedAtMs < since else { return }
            self.clear()
        }
    }

    /// The session is gone: a call on screen says "Lost connection to the phone" once it has been gone for
    /// `connectionLostDelay`, until it comes back (CALL-03 E6).
    public func disconnected() {
        peer = nil
        staleTask?.cancel()
        connectionLostTask?.cancel()
        guard let current = call, current.phase != .ended else { return }
        let callId = current.callId
        connectionLostTask = Task { [weak self, clock, connectionLostDelay] in
            try? await clock.sleep(for: connectionLostDelay)
            guard !Task.isCancelled, let self, self.peer == nil, var call = self.call, call.callId == callId,
                  call.phase != .ended else { return }
            call.connectionLost = true
            self.call = call
        }
    }
}
