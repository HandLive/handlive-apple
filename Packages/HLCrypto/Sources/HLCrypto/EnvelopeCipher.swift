import Foundation
import HLProtocol

/// Mã hóa envelope (0.5.1): payload = b64(`nonce(24) ‖ ciphertext ‖ tag(16)`), AAD = `"<v>|<type>|<id>|<ts>"`.
public enum EnvelopeCipher {
    public static func seal(type: MessageType, plaintext: Data, key: Data, id: String = HLUUID.v7(),
                            ts: Int64 = HLUUID.currentTimeMs(),
                            nonce: Data = XChaCha20Poly1305.randomNonce()) throws -> Envelope {
        let aad = Envelope(type: type, id: id, ts: ts, payload: "").aad
        let sealed = try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce, aad: aad)
        return Envelope(type: type, id: id, ts: ts, payload: Base64Coding.encodeB64(sealed.combined))
    }

    /// Bên nhận dựng AAD từ chính các trường của envelope; sửa `type`/`id`/`ts` → `authenticationFailed`.
    public static func open(_ envelope: Envelope, key: Data) throws -> Data {
        try XChaCha20Poly1305.open(combined: try envelope.payloadBytes, key: key, aad: envelope.aad)
    }
}
