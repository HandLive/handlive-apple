import Foundation
import HLCrypto
import HLProtocol

extension ConnectionManager {
    // MARK: - Watchers

    func watchNetwork() async {
        for await status in network.updates() {
            let previous = networkPath
            networkPath = status
            let change = switch (previous?.satisfied, status.satisfied) {
            case (true?, false): "down"
            case (false?, true), (nil, true): "up"
            case (nil, false): "down"
            default: previous?.signature == status.signature ? "" : "changed"
            }
            if change.isEmpty { continue }
            BenchLog.event("net", ["change": change])
            signals.post(.network)
        }
    }

    func watchDiscovery() async {
        for await event in discovery.events() {
            switch event {
            case .results(let phones):
                if Set(phones.map(\.name)) != Set(discovered.map(\.name)) { upgradeTried.removeAll() }
                discovered = phones
                signals.post(.discovery)
            case .state(let state):
                discoveryState = state
                let denied = state == .localNetworkDenied
                if denied != (issue == .localNetworkDenied) {
                    issue = denied ? .localNetworkDenied : nil
                    publishStatus()
                }
            }
        }
    }

    /// Forwards the relay connection's events to the manager's loop.
    func watchRelay(_ link: RelayLink) {
        workers.append(Task { [signals] in
            for await event in link.events { signals.post(.relay(event)) }
        })
    }

    /// Instances whose TXT hint matches the pair at this hour (CONN-01 step 3).
    func matchingCandidates() -> [DiscoveredPhone] {
        guard let phone,
              let hints = try? DiscoveryHint.acceptedHints(prk: phone.pair.prk, nowMs: HLUUID.currentTimeMs())
        else { return [] }
        return discovered.filter { $0.speaksProtocolV1 && DiscoveryHint.matches(txtValue: $0.hints, accepted: hints) }
    }
}
