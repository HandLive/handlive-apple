import Foundation
import HLProtocol

extension ConnectionManager {
    // MARK: - The pair on the relay (PAIR-01 API 8, PAIR-02 API 1, CONN-03 E4)

    /// PAIR-01 API 8: success → `relay_registered = 1`; a failure keeps it at 0 for the next connection (E8). The API
    /// already registered this device again after a first 404; a second 404 (the phone is unknown to the relay) or any
    /// other 4xx waits 24 h (logic 6); a network or server error tries again at the next connection.
    func registerPair(_ registration: RelayPairRegistration, _ relay: RelayServices) async {
        if let until = pairRegistrationPausedUntil[registration.pairId], ContinuousClock.now < until { return }
        do {
            try await relay.api.registerPair(registration)
        } catch RelayAPIError.http(let status, _, _) where (400..<500).contains(status) {
            // The second 404, or any other 4xx: no new call for 24 h.
            pairRegistrationPausedUntil[registration.pairId] = .now.advanced(by: configuration.pairRegistrationPause)
            return
        } catch {
            return
        }
        pairRegistered(registration.pairId)
    }

    private func pairRegistered(_ pairId: String) {
        pairRegistrationPausedUntil[pairId] = nil
        if phone?.pair.pairId == pairId { phone?.relayRegistration = nil }
        eventSink.yield(.relayPairRegistered(pairId: pairId))
    }

    /// CONN-03 E4 and PAIR-02 API 1 logic 3: what the relay says about the pair. Revoked there → PAIR-03 flow B;
    /// listed while still unregistered here → the phone completed the registration (`relay_registered = 1`, which also
    /// ends a 24 h wait); unknown there → the phone left the relay or the pair was never registered: register it
    /// again when possible, keep the LAN.
    func checkPairOnRelay() async {
        guard let phone, let relay, let list = try? await relay.api.pairs() else { return }
        if let entry = list.pairs.first(where: { $0.pairId == phone.pair.pairId }) {
            guard entry.revokedAt != nil else {
                if phone.relayRegistration != nil { pairRegistered(phone.pair.pairId) }
                return
            }
            if let current = session {
                session = nil
                await current.close(bye: nil)
                eventSink.yield(.disconnected)
            }
            await closeRelay()
            removePair(.revoked)
        } else {
            eventSink.yield(.relayPairMissing(pairId: phone.pair.pairId))
            if let registration = phone.relayRegistration { await registerPair(registration, relay) }
        }
    }
}
