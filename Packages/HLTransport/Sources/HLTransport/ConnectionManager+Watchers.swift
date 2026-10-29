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

    func watchBluetoothCentral() async {
        for await event in bluetooth.events() {
            switch event {
            case .poweredOn:
                bluetoothPowered = true
                scheduleBluetoothSignal()
            case .poweredOff:
                bluetoothPowered = false
                bluetoothDiscovered = []
                bluetoothSettled = false
                bluetoothSignalTask?.cancel()
                bluetoothSignalTask = nil
            case .results(let advertisements):
                bluetoothDiscovered = advertisements
                scheduleBluetoothSignal()
            }
        }
    }

    /// Coalesces a burst of `bluetooth.events()` into one `.bluetooth` signal: CoreBluetooth can fire
    /// `didDiscover` again right after a rotation (0.4.5 "Rotation" — new PSM, new advertising set, same
    /// `BT_HINT_PERIOD`), and `ConnectionManager` is an actor with `watchBluetoothCentral()` and `run()` as two
    /// separate tasks, so posting on every event risked the run loop reading `bluetoothDiscovered` between two
    /// advertisements of the same rotation and opening the stale PSM. Restarting this task on every event means
    /// the signal only fires once the burst has quieted down, by which point `bluetoothDiscovered` already holds
    /// the latest snapshot. `bluetoothSettled` gates the candidates themselves, not just the signal: the run loop
    /// also reads them when another signal (network, mDNS) wakes it, or right after entering `Discovering`.
    private func scheduleBluetoothSignal() {
        bluetoothSettled = false
        bluetoothSignalTask?.cancel()
        bluetoothSignalTask = Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            self.bluetoothSettled = true
            self.signals.post(.bluetooth)
        }
    }

    /// Advertisements whose hint matches the pair in the epoch window `e − 4`…`e + 4` (0.4.5 "Advertisement",
    /// CONN-05 step 3); empty whenever the radio is off (E1) or a burst of scan events is still arriving.
    func matchingBluetoothCandidates() -> [BluetoothAdvertisement] {
        guard bluetoothPowered, bluetoothSettled, let phone else { return [] }
        let accepted = BtAdvertisementHint.acceptedHints(prk: phone.pair.prk, nowMs: HLUUID.currentTimeMs())
        return bluetoothDiscovered.filter { BtAdvertisementHint.matches(advertised: $0.serviceData.hints, accepted: accepted) }
    }
}
