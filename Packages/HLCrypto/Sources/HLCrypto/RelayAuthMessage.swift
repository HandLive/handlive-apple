import Foundation
import HLProtocol

/// Messages a device signs with `ik_sig` for the relay (0.6.4, CONN-03 API 1 and 3); used from Phase 2.
public enum RelayAuthMessage {
    /// `POST /v1/devices`: `"HLREG1"` ‖ `device_id` (16) ‖ `ik_sig_pub` (32) ‖ UTF-8(`platform`) ‖ `ts` (int64 BE).
    public static func register(deviceId: String, signingPublicKey: Data, platform: String, ts: Int64) throws -> Data {
        try Bytes.require(signingPublicKey, count: 32)
        var message = Data("HLREG1".utf8) + (try HLUUID.bytes(from: deviceId)) + signingPublicKey + Data(platform.utf8)
        withUnsafeBytes(of: ts.bigEndian) { message.append(contentsOf: $0) }
        return message
    }

    /// `POST /v1/auth/token`: `"HLAUTH1"` ‖ challenge (32 raw bytes, b64u-decoded) ‖ `device_id` (16).
    public static func token(challenge: Data, deviceId: String) throws -> Data {
        try Bytes.require(challenge, count: 32, isNonce: true)
        return Data("HLAUTH1".utf8) + challenge + (try HLUUID.bytes(from: deviceId))
    }
}
