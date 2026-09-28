import Foundation
import HLProtocol

/// The revocation statement `HLREVOKE1` (0.6.2, PAIR-03): the revoking device signs
/// `"HLREVOKE1"` ‖ `pair_id` (16) ‖ `by` = its `device_id` (16) ‖ `revoked_at` (uint64 BE, ms) with `ik_sig`, so a relay
/// can never unpair a device on its own.
public enum RevokeStatement {
    static let label = Data("HLREVOKE1".utf8)

    /// The 49 signed bytes.
    public static func message(pairId: String, by: String, revokedAt: Int64) throws -> Data {
        var message = label + (try HLUUID.bytes(from: pairId)) + (try HLUUID.bytes(from: by))
        withUnsafeBytes(of: UInt64(bitPattern: revokedAt).bigEndian) { message.append(contentsOf: $0) }
        return message
    }

    /// `sig` of the statement, 64 bytes.
    public static func sign(pairId: String, by: String, revokedAt: Int64, seed: Data) throws -> Data {
        try Ed25519.sign(try message(pairId: pairId, by: by, revokedAt: revokedAt), seed: seed)
    }

    /// Strict verification (0.6.5) of `signature` over the statement with `publicKey`, the stored `ik_sig` of `by`.
    public static func verify(_ signature: Data, pairId: String, by: String, revokedAt: Int64, publicKey: Data) -> Bool {
        guard let message = try? message(pairId: pairId, by: by, revokedAt: revokedAt) else { return false }
        return Ed25519.verify(signature, message: message, publicKey: publicKey)
    }
}
