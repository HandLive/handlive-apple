import Foundation
import HLAppCore
import HLCrypto
import HLProtocol
import HLSMS
import HLTransport

/// Result of unpairing (PAIR-03 field 4).
public enum IOSUnpairResult: Equatable, Sendable {
    /// Both sides cleaned up.
    case done
    /// Cleaned up here; the phone cleans up when it reconnects (flow B).
    case donePendingRemote
}

extension IOSAppModel: PairingHost {
    public var pairingDeviceName: String { device.name }

    /// The relay for the QR code's rendezvous (PAIR-01 step 2) while the internet connection is on.
    public var pairingRelay: RelayServices? { relayEnabled ? relay : nil }

    /// This device as pairing presents it (PAIR-01 API 2).
    public func pairingIdentity() -> PairingIdentity? {
        guard let identity else { return nil }
        return PairingIdentity(deviceId: identity.deviceId, name: PairingInvite.fittedName(device.name),
                               platform: device.platform, model: device.model, signingSeed: identity.signingSeed,
                               signingPublicKey: identity.signingPublicKey, dhPrivateKey: identity.keyAgreementPrivateKey,
                               dhPublicKey: identity.keyAgreementPublicKey)
    }

    /// PAIR-01 API 5 logic 2: `PRK` into the Keychain, the record into the store, and only then success.
    public func completePairing(_ result: PairingResult) throws {
        guard let store else { throw IOSPairingError.notReady }
        let account = SecretAccount.pairKey(pairId: result.pairId)
        try secrets.save(result.prk, account: account)
        let record = PairedDeviceRecord(
            pairId: result.pairId, peerDeviceId: result.phoneDeviceId, peerName: result.phoneName,
            peerModel: result.phoneModel, peerSigningPublicKey: result.phoneSigningPublicKey,
            peerKeyAgreementPublicKey: result.phoneDHPublicKey, peerCertificateSHA256: result.certificateSHA256,
            attestation: result.attestation, signatureSelf: result.signatureSelf, signaturePeer: result.signaturePeer,
            createdAt: result.createdAt)
        do {
            try store.upsert(record)
        } catch {
            try? secrets.delete(account: account)
            throw error
        }
        pairedDevice = record
        pairChangedForMessages()
        let phone = activePhone()
        Task { await manager?.setPhone(phone) }
    }

    /// PAIR-03 flow A: `pair/revoke {reason: user}` with an `ack` wait of 10 s when connected, then everything of the
    /// pair goes here whatever the phone answered (flow B, revoked on the relay, when it did not).
    @discardableResult
    public func unpair() async -> IOSUnpairResult {
        guard let record = pairedDevice else { return .done }
        var result = IOSUnpairResult.donePendingRemote
        if let session = await manager?.currentSession {
            let revoke = PairRevokeData(pairId: record.pairId, reason: .user)
            if let ack = try? await session.request(.pair, op: "revoke", data: revoke), ack.ok { result = .done }
        }
        forgetPair(relayReason: result == .done ? .user : .lostDevice)
        await manager?.setPhone(nil)
        return result
    }

    /// PAIR-03 step 7: the `PRK` first, then the record — kept as a tombstone while the pair must still be revoked on
    /// the relay (steps 8–9, E3) — the last received clip and the pair's messages.
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
        received = nil
        forgetMessages(pairId: record.pairId)
    }

    /// PAIR-03 steps 8–9 and E3: each tombstone is revoked on the relay, then deleted for good.
    func revokeTombstones(reason: RelayPairRevokeRequest.Reason = .user) async {
        guard let api = relay?.api, let store else { return }
        for record in (try? store.all()) ?? [] where record.revokedAt != nil {
            do {
                try await api.revokePair(pairId: record.pairId, reason: reason)
            } catch RelayAPIError.http(403, _, _) {
                // NOT_PAIRED: this device is not a member any more, so there is nothing left to revoke.
            } catch {
                return
            }
            try? store.remove(pairId: record.pairId)
        }
    }

    // MARK: - Push token (CONN-04 API 1, SET-03 step 13)

    /// The APNs device token from `didRegisterForRemoteNotificationsWithDeviceToken`; sent when the relay can be used.
    public func pushTokenReceived(_ token: Data) {
        if token != pushToken { pushTokenSent = false }
        pushToken = token
        Task { await sendPushToken() }
    }

    /// `PUT /v1/devices/me/push-token` with the lowercase hex token and the app's topic; retried at the next
    /// connection when it failed.
    func sendPushToken() async {
        guard !pushTokenSent, relayEnabled, let token = pushToken, let api = relay?.api else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let request = RelayPushTokenRequest(provider: pushProvider, token: hex, topic: pushTopic)
        guard (try? await api.updatePushToken(request)) != nil else { return }
        pushTokenSent = true
    }

    // MARK: - Settings (SET-02)

    public func setClipboardEnabled(_ enabled: Bool) {
        settings.clipboardEnabled = enabled
        clipboardEnabled = enabled
        scheduleCapabilityUpdate()
    }

    public func setSendImages(_ enabled: Bool) {
        settings.sendImages = enabled
        sendImages = enabled
        scheduleCapabilityUpdate()
    }

    /// Local only (CLIP-05): applies to clips received afterwards.
    public func setAutoClearSeconds(_ seconds: Int) {
        settings.autoClearSeconds = seconds
        autoClearSeconds = settings.autoClearSeconds
        clipboard?.autoClearSettingChanged()
    }

    /// SET-02 field 21: the capability tells the phone first, then the relay session and connection close (step 6);
    /// turned on, the push token is registered again (API 6).
    public func setRelayEnabled(_ enabled: Bool) {
        settings.relayEnabled = enabled
        relayEnabled = enabled
        relayNotice = nil
        if enabled { pushTokenSent = false }
        scheduleCapabilityUpdate()
        Task { [manager] in
            try? await Task.sleep(for: .milliseconds(400)) // after the coalesced capability/update
            await manager?.setRelayEnabled(enabled)
            await self.sendPushToken()
        }
    }
}

/// The pair could not be stored after a successful exchange.
public enum IOSPairingError: Error, Equatable {
    /// The keys or the pair store are not loaded (SET-03 E1).
    case notReady
}
