import Foundation
import HLAppCore
import HLDesignSystem
import HLLocalization
import HLProtocol
import HLSMS
import HLSMSUI
import HLTransport

extension IOSAppModel {
    /// Connection manager events (CONN-01 step 10, CONN-02, CONN-03, PAIR-03 flow B).
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
            Task {
                await sendPushToken()
                await revokeTombstones() // PAIR-03 E3: a network is back
            }
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
            let phone = activePhone() // carries the registration again, retried when a network is there
            Task { await manager?.setPhone(phone) }
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

    /// PAIR-02 step 4: what the relay says about the pair, when the phone's details open (at most once a minute).
    public func refreshPairOnRelay() {
        Task { await manager?.refreshPairOnRelay() }
    }
}

extension HLConnectionStatus {
    /// StatusIndicator state of a link status (0.11, PAIR-02 field 4), as on the Mac.
    init(link: LinkStatus, lastSeen: Int64?) {
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

extension IOSAppModel {
    /// The relay's problem under the "Internet Connection" switch (CONN-03 E3, E6, E7), or a relay account result.
    public func relayProblemText(now: Date = Date()) -> String? {
        switch link.issue {
        case .relayUntrusted?: return L10n.Error.relayPinMismatch
        case .relayDeviceRemoved?: return L10n.Error.relayDeviceRevoked
        case .relayRateLimited?:
            let seconds = max(1, (link.nextRetry ?? now).timeIntervalSince(now).rounded(.up))
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = seconds >= 60 ? [.minute] : [.second]
            let duration = formatter.string(from: seconds >= 60 ? (seconds / 60).rounded(.up) * 60 : seconds) ?? ""
            return L10n.Error.relayRateLimited(duration: duration)
        default: return relayNotice
        }
    }

    /// Why SMS does not work with the phone while it is on here (2-patterns/04-cai-dat.md), or `nil`.
    public var smsPhoneProblem: SmsPhoneProblem? {
        guard smsEnabled, let device = pairedDevice else { return nil }
        return SmsPhoneProblem.of(device.peerCapability, phoneName: device.peerName)
    }

    /// PAIR-02 field 8: why SMS is not in use with the phone, off on this device included, or `nil` when it is.
    public var smsFeatureReason: String? {
        guard pairedDevice != nil else { return nil }
        guard smsEnabled else { return L10n.Pairing.reasonOffOnDevice(deviceName: device.name) }
        return smsPhoneProblem?.text
    }

    /// PAIR-02 field 8: why clipboard sync is not in use with the phone, off on this device included, or `nil`.
    public var clipboardFeatureReason: String? {
        guard pairedDevice != nil else { return nil }
        guard clipboardEnabled else { return L10n.Pairing.reasonOffOnDevice(deviceName: device.name) }
        return clipboardUnavailableReason
    }

    /// SMS-01 field 8: names can't be shown because the phone may not read contacts.
    public var phoneMissesContactsPermission: Bool {
        SmsPermissions.contactsMissing(in: pairedDevice?.peerCapability?.permissionsMissing ?? [])
    }

    /// Why clipboard sync is not in effect with the phone (SET-02 field 24), or `nil`.
    public var clipboardUnavailableReason: String? {
        guard clipboardEnabled, let device = pairedDevice else { return nil }
        if device.peerCapability?.features.clipboard?.enabled == false {
            return L10n.Pairing.reasonOffOnDevice(deviceName: device.peerName)
        }
        return nil
    }
}
