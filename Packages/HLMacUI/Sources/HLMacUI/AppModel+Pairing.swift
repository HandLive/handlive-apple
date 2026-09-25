import Foundation
import HLAppCore
import HLCrypto
import HLLocalization
import HLProtocol
import HLTransport

/// The pair could not be stored after a successful exchange.
public enum PairingSaveError: Error, Equatable {
    /// The keys or the pair store are not loaded (SET-03 E1).
    case notReady
}

/// Result of unpairing (PAIR-03 field 4).
public enum UnpairResult: Equatable, Sendable {
    /// Both sides cleaned up.
    case done
    /// Cleaned up here; the phone cleans up when it reconnects (flow B).
    case donePendingRemote
}

extension AppModel {
    /// Why clipboard sync is not in effect with the phone (SET-02 field 24), or `nil` when it is.
    public var clipboardUnavailableReason: String? {
        guard let device = pairedDevice else { return nil }
        if !clipboardEnabled { return L10n.Pairing.reasonOffOnDevice(deviceName: self.device.name) }
        if device.peerCapability?.features.clipboard?.enabled == false {
            return L10n.Pairing.reasonOffOnDevice(deviceName: device.peerName)
        }
        return nil
    }

    /// This Mac as pairing presents it (PAIR-01 API 2); the fitted name goes into both the QR code and `pair/hello`.
    public func pairingIdentity() -> PairingIdentity? {
        guard let identity else { return nil }
        return PairingIdentity(deviceId: identity.deviceId, name: PairingInvite.fittedName(device.name), platform: .macos,
                               model: MacHardware.modelIdentifier, signingSeed: identity.signingSeed,
                               signingPublicKey: identity.signingPublicKey, dhPrivateKey: identity.keyAgreementPrivateKey,
                               dhPublicKey: identity.keyAgreementPublicKey)
    }

    /// PAIR-01 API 5 logic 2: `PRK` into the Keychain (account = `pair_id`), the record into the store, and only then
    /// success; the connection manager then connects to the new phone (step 12 → CONN-01).
    public func completePairing(_ result: PairingResult) throws {
        guard let store else { throw PairingSaveError.notReady }
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
        let phone = activePhone()
        Task { await manager?.setPhone(phone) }
    }

    /// PAIR-03 flow A: `pair/revoke {reason: user}` with an `ack` wait of 10 s when connected, then delete the `PRK`
    /// and the record here whatever the phone answered (flow B when it did not).
    @discardableResult
    public func unpair() async -> UnpairResult {
        guard let record = pairedDevice else { return .done }
        var result = UnpairResult.donePendingRemote
        if let session = await manager?.currentSession {
            let revoke = PairRevokeData(pairId: record.pairId, reason: .user)
            if let ack = try? await session.request(.pair, op: "revoke", data: revoke), ack.ok { result = .done }
        }
        forgetPair()
        await manager?.setPhone(nil)
        return result
    }
}
