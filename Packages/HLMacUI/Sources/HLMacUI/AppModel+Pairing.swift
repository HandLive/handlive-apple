import Foundation
import HLAppCore
import HLCrypto
import HLLocalization
import HLProtocol
import HLTransport

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
