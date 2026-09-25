import Foundation
import HLAppCore
import HLCrypto
import HLDesignSystem
import HLProtocol
import HLTransport

extension AppModel {
    /// Connection manager events (CONN-01 step 10, CONN-02, PAIR-03 flow B).
    func handle(_ event: LinkEvent) async {
        switch event {
        case .status(let status):
            link = status
        case .connected(_, let details):
            updatePairRecord { record in
                record.lastHost = details.host
                record.lastPort = details.port
                record.lastSeenAt = HLUUID.currentTimeMs()
                record.peerCapability = details.peerCapability
            }
        case .capabilityUpdated(let capability):
            updatePairRecord { $0.peerCapability = capability }
        case .disconnected:
            updatePairRecord { $0.lastSeenAt = HLUUID.currentTimeMs() }
        case .message:
            break // feature modules (clipboard) subscribe through `AppModel+Clipboard`
        case .pairRemoved:
            forgetPair()
        }
    }

    func updatePairRecord(_ change: (inout PairedDeviceRecord) -> Void) {
        guard let store, let pairId = pairedDevice?.pairId else { return }
        try? store.update(pairId: pairId, change)
        pairedDevice = try? store.active()
    }

    /// PAIR-03 step 7 on this side: delete the `PRK` from the Keychain before anything else, then the record.
    /// Phase 1 never registers pairs with the relay, so no tombstone is kept.
    func forgetPair() {
        guard let record = pairedDevice else { return }
        try? secrets.delete(account: SecretAccount.pairKey(pairId: record.pairId))
        try? store?.remove(pairId: record.pairId)
        pairedDevice = nil
    }
}

extension HLConnectionStatus {
    /// StatusIndicator state of a link status (0.11, PAIR-02 field 4). `lastSeen` is `last_seen_at` in Unix ms.
    public init(link: LinkStatus, lastSeen: Int64?) {
        switch link.status {
        case .notPaired: self = .notPaired
        case .needsRepair: self = .needsRepair
        case .connecting: self = .connecting
        case .disconnected: self = .networkLost
        case .connected(.lan): self = .connectedWiFi
        case .connected(.relay): self = .connectedInternet
        case .phoneOffline:
            let time = lastSeen.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000).formatted(date: .omitted, time: .shortened)
            }
            self = .phoneOffline(lastSeen: time)
        }
    }
}
