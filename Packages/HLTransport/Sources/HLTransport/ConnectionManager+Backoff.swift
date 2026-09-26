import Foundation
import HLCrypto
import HLProtocol

extension ConnectionManager {
    // MARK: - Backoff

    func waitBackoff() async {
        let delay = pendingDelay
        nextRetry = delay.map { Date().addingTimeInterval($0.timeInterval) }
        publishStatus()
        let deadline = delay.map { ContinuousClock.now.advanced(by: $0) }
        signals.drain { if case .sessionEnded = $0 { false } else { $0 != .discovery && $0 != .network } }
        while machine.state == .backoff && !Task.isCancelled {
            if sleeping {
                if await signals.next(timeout: nil) == .wake { apply(.backoffElapsed) }
                continue
            }
            let remaining = deadline.map { ContinuousClock.now.duration(to: $0) }
            if let remaining, remaining <= .zero { return apply(.backoffElapsed) }
            let signal = await signals.next(timeout: remaining)
            if signal == nil && remaining == nil { continue } // cancelled
            if let event = backoffEvent(after: signal) { return apply(event) }
        }
    }

    /// Whether a signal (or the timeout, `nil`) ends the backoff wait (CONN-02 steps 4–5).
    private func backoffEvent(after signal: ManagerSignal?) -> ConnectionEvent? {
        switch signal {
        case nil, .reconnectNow?, .wake?: return .backoffElapsed
        case .network?: return networkUp ? .networkChanged : .networkLost
        case .discovery?: return issue != .authFailed && freshCandidateVisible ? .backoffElapsed : nil
        case .phoneChanged?: return phone == nil ? .unpaired : nil
        default: return nil
        }
    }

    /// A phone with a current hint is visible (it just came back on the LAN).
    private var freshCandidateVisible: Bool {
        guard let phone, let hints = try? DiscoveryHint.acceptedHints(prk: phone.pair.prk, nowMs: HLUUID.currentTimeMs())
        else { return false }
        return discovered.contains { $0.speaksProtocolV1 && DiscoveryHint.matches(txtValue: $0.hints, accepted: hints) }
    }

    /// Chooses the wait of the next `Backoff` from the reaction (CONN-01 E3, E5; CONN-02).
    func scheduleBackoff(_ reaction: CloseReaction, minProtocol: Int32? = nil) {
        switch reaction {
        case .backoff, .none:
            pendingDelay = .seconds(backoff.nextDelay() * configuration.delayScale)
        case .backoffAfterAuthFailure:
            issue = .authFailed
            pendingDelay = .seconds(ReconnectBackoff.authFailedDelay * configuration.delayScale)
        case .updateRequired:
            issue = (minProtocol ?? 0) > currentProtocolVersion ? .updateThisApp : .updatePhoneApp
            pendingDelay = nil // no point retrying until one side updates; Reconnect Now still works
        case .removePair:
            pendingDelay = nil
        }
    }
}
