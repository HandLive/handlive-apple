import Foundation
import HLProtocol

/// Khóa phiên sau bắt tay/rekey: `secret` 64 byte = `k_c2s`(32) ‖ `k_s2c`(32).
/// c2s = Mac/iOS → Android, s2c = Android → Mac/iOS (theo vai C/S, không theo bên khởi tạo rekey).
public struct SessionKeys: Equatable, Sendable {
    public let secret: Data

    public init(secret: Data) throws {
        try Bytes.require(secret, count: 64)
        self.secret = Data(secret)
    }

    public var clientToServer: Data { secret.prefix(32) }
    public var serverToClient: Data { secret.suffix(32) }

    /// Rekey (0.6.3 bước 6, 8): ikm = X25519(eph bên khởi tạo, eph bên nhận) ‖ `secret` cũ;
    /// salt = SHA-256(`nonce` bên khởi tạo ‖ `nonce` bên nhận); info `"handlive/v1/rekey"`; L = 64. `epoch` không vào KDF.
    public func rekeyed(ephemeralShared: Data, initiatorNonce: Data, responderNonce: Data) throws -> SessionKeys {
        try Bytes.require(ephemeralShared, count: 32)
        try Bytes.require(initiatorNonce, count: 32, isNonce: true)
        try Bytes.require(responderNonce, count: 32, isNonce: true)
        let salt = HMACSHA256.sha256(initiatorNonce + responderNonce)
        return try SessionKeys(secret: HKDFSHA256.derive(
            ikm: ephemeralShared + secret, salt: salt, info: SessionHandshakeCrypto.rekeyInfo, length: 64
        ))
    }
}
