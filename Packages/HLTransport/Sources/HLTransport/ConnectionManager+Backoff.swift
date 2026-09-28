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
        signals.drain { signal in
            switch signal {
            case .sessionEnded, .pairRevoked, .relay, .discovery, .network: false
            default: true
            }
        }
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
        case .relaySettingChanged?: return relayUsable ? .backoffElapsed : nil
        default: return nil
        }
    }

    /// A phone with a current hint is visible (it just came back on the LAN).
    private var freshCandidateVisible: Bool {
        !matchingCandidates().isEmpty
    }

    /// Chooses the wait of the next `Backoff` from the reaction (CONN-01 E3, E5; CONN-02). `keepSchedule`: the error
    /// came over the relay before the phone was authenticated, so it may be forged — its message is shown but the
    /// normal schedule goes on, never a stop or the 5-minute wait (CONN-03 E9).
    func scheduleBackoff(_ reaction: CloseReaction, minProtocol: Int32? = nil, keepSchedule: Bool = false) {
        let normalDelay = { Duration.seconds(self.backoff.nextDelay() * self.configuration.delayScale) }
        switch reaction {
        case .backoff, .none:
            pendingDelay = normalDelay()
        case .backoffAfterAuthFailure:
            issue = .authFailed
            pendingDelay = keepSchedule ? normalDelay() : .seconds(ReconnectBackoff.authFailedDelay * configuration.delayScale)
        case .updateRequired:
            issue = (minProtocol ?? 0) > currentProtocolVersion ? .updateThisApp : .updatePhoneApp
            // No point retrying until one side updates (Reconnect Now still works), unless the error may be forged.
            pendingDelay = keepSchedule ? normalDelay() : nil
        case .removePair:
            pendingDelay = nil
        }
    }
}
