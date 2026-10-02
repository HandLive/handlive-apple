import Foundation
import HLProtocol

extension AppCallController {
    /// A session reached `Connected`: commands go through it, and "Lost connection" clears. The phone sends every live
    /// app call right after the capability exchange (CALL-05 API 1 logic 7), so a call it does not mention within
    /// `reconnectGrace` ended while the session was down and goes.
    public func connected(peer: any CallPeer, capability: CapabilityData) {
        self.peer = peer
        connectionLostTask?.cancel()
        staleTask?.cancel()
        connectedAtMs = now()
        capabilityUpdated(capability)
        for callId in Array(contexts.keys) where contexts[callId]?.connectionLost == true {
            change(callId) { $0.connectionLost = false }
        }
        guard !contexts.isEmpty else { return }
        let since = connectedAtMs
        staleTask = Task { [weak self, reconnectGrace] in
            try? await Task.sleep(for: reconnectGrace)
            guard !Task.isCancelled, let self else { return }
            for (callId, call) in self.contexts where call.receivedAtMs < since {
                self.cancelTasks(of: callId)
                self.contexts[callId] = nil
            }
            self.publish()
        }
    }

    /// The session is gone: a call on screen says "Lost connection to the phone" once it has been gone for
    /// `connectionLostDelay`, until it comes back.
    public func disconnected() {
        peer = nil
        connectionLostTask?.cancel()
        guard !contexts.isEmpty else { return }
        connectionLostTask = Task { [weak self, connectionLostDelay] in
            try? await Task.sleep(for: connectionLostDelay)
            guard !Task.isCancelled, let self, self.peer == nil else { return }
            for callId in Array(self.contexts.keys) {
                self.change(callId) { $0.connectionLost = true }
            }
        }
    }
}
