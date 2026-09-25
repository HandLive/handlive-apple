import Foundation
import HLProtocol

/// Bắt tay `/v1/ctl` (0.6.3 bước 1–3, 8). `T1`, `T2` ghép byte thô: nhãn ASCII ‖ uuid 16 ‖ eph 32 ‖ nonce 32.
public enum SessionHandshakeCrypto {
    public static let authInfo = "handlive/v1/session-auth"
    public static let sessionInfo = "handlive/v1/session"
    public static let rekeyInfo = "handlive/v1/rekey"
    public static let nonceByteCount = 32

    /// `K_auth` = HKDF(ikm = `PRK`, salt rỗng, info `"handlive/v1/session-auth"`, L = 32).
    public static func authKey(prk: Data) throws -> Data {
        try Bytes.require(prk, count: 32)
        return HKDFSHA256.derive(ikm: prk, info: authInfo, length: 32)
    }

    /// `T1` = `"HL1|hello|"` ‖ `pair_id` ‖ `device_id`C ‖ `eph`C ‖ `nonce`C (106 byte).
    public static func helloTranscript(pairId: String, clientDeviceId: String,
                                       clientEph: Data, clientNonce: Data) throws -> Data {
        try Bytes.require(clientEph, count: 32)
        try Bytes.require(clientNonce, count: nonceByteCount, isNonce: true)
        return Data("HL1|hello|".utf8) + (try HLUUID.bytes(from: pairId))
            + (try HLUUID.bytes(from: clientDeviceId)) + clientEph + clientNonce
    }

    /// `T2` = `"HL1|welcome|"` ‖ `T1` ‖ `device_id`S ‖ `eph`S ‖ `nonce`S (198 byte).
    public static func welcomeTranscript(helloTranscript: Data, serverDeviceId: String,
                                         serverEph: Data, serverNonce: Data) throws -> Data {
        try Bytes.require(serverEph, count: 32)
        try Bytes.require(serverNonce, count: nonceByteCount, isNonce: true)
        return Data("HL1|welcome|".utf8) + helloTranscript
            + (try HLUUID.bytes(from: serverDeviceId)) + serverEph + serverNonce
    }

    /// `secret` = HKDF(ikm = X25519(eph) ‖ `PRK`, salt = SHA-256(`T2`), info `"handlive/v1/session"`, L = 64).
    public static func sessionKeys(ephemeralShared: Data, prk: Data, welcomeTranscript: Data) throws -> SessionKeys {
        try Bytes.require(ephemeralShared, count: 32)
        try Bytes.require(prk, count: 32)
        let salt = HMACSHA256.sha256(welcomeTranscript)
        return try SessionKeys(secret: HKDFSHA256.derive(
            ikm: ephemeralShared + prk, salt: salt, info: sessionInfo, length: 64
        ))
    }

    public static func randomNonce() -> Data {
        Bytes.random(nonceByteCount)
    }
}
