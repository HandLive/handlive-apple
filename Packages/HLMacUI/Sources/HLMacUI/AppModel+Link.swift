import Foundation
import HLAppCore
import HLCrypto
import HLDesignSystem
import HLLocalization
import HLProtocol
import HLTransport

extension AppModel {
    /// Connection manager events (CONN-01 step 10, CONN-02, PAIR-03 flow B).
    func handle(_ event: LinkEvent) async {
        defer { messagesLinkEvent(event) }
        switch event {
        case .status(let status):
            link = status
        case .connected(let session, let details):
            updatePairRecord { record in
                if let host = details.host, let port = details.port { // a relay session keeps the LAN address
                    record.lastHost = host
                    record.lastPort = port
                }
                record.lastSeenAt = HLUUID.currentTimeMs()
                record.peerCapability = details.peerCapability
            }
            clipboardConnected(session, details: details)
            Task { await revokeTombstones() } // PAIR-03 E3: a network is back
        case .capabilityUpdated(let capability):
            updatePairRecord { $0.peerCapability = capability }
            clipboard?.phoneCapabilityUpdated(capability.features.clipboard)
        case .disconnected:
            updatePairRecord { $0.lastSeenAt = HLUUID.currentTimeMs() }
            clipboard?.phoneDisconnected()
        case .message(let envelope):
            if envelope.type == .clipboard { clipboard?.receive(envelope) }
        case .pairRemoved:
            forgetPair()
        case .relayPairRegistered, .relayPairMissing, .relayDeviceRevoked:
            handleRelayAccountEvent(event)
        }
    }

    /// `relay_registered` follows the relay (PAIR-01 API 8, PAIR-02 API 1 logic 3); `410` turns the relay off (CONN-03 E3).
    private func handleRelayAccountEvent(_ event: LinkEvent) {
        switch event {
        case .relayPairRegistered(let pairId) where pairId == pairedDevice?.pairId:
            updatePairRecord { $0.relayRegistered = true }
        case .relayPairMissing(let pairId) where pairId == pairedDevice?.pairId:
            updatePairRecord { $0.relayRegistered = false }
        case .relayDeviceRevoked:
            settings.relayEnabled = false
            relayEnabled = false
            relayNotice = L10n.Error.relayDeviceRevoked
        default:
            break
        }
    }

    func updatePairRecord(_ change: (inout PairedDeviceRecord) -> Void) {
        guard let store, let pairId = pairedDevice?.pairId else { return }
        try? store.update(pairId: pairId, change)
        pairedDevice = try? store.active()
    }

    /// PAIR-03 step 7 on this side: delete the `PRK` from the Keychain before anything else, then the record — kept
    /// as a tombstone while the pair still has to be revoked on the relay (steps 8–9, E3).
    func forgetPair(relayReason: RelayPairRevokeRequest.Reason = .user) {
        guard let record = pairedDevice else { return }
        try? secrets.delete(account: SecretAccount.pairKey(pairId: record.pairId))
        if record.relayRegistered, relay != nil {
            try? store?.update(pairId: record.pairId) { $0.revokedAt = HLUUID.currentTimeMs() }
            Task { await revokeTombstones(reason: relayReason) }
        } else {
            try? store?.remove(pairId: record.pairId)
        }
        pairedDevice = nil
        clipboard?.phoneDisconnected()
        updateClipboardPolling()
        forgetMessages(pairId: record.pairId)
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
