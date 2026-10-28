import CryptoKit
import Foundation

/// AEAD_ChaCha20_Poly1305 (RFC 8439), nonce 12 byte do bên gọi chỉ định — khác `XChaCha20Poly1305` (nonce 24 byte,
/// dẫn subkey qua HChaCha20). Dùng cho Noise (0.4.5): nonce không bao giờ sinh ngẫu nhiên ở đây, luôn là 4 byte 0
/// ‖ bộ đếm 64-bit LE theo đúng cấu trúc CipherState của Noise.
public enum ChaCha20Poly1305 {
    public static let keyByteCount = 32
    public static let nonceByteCount = 12
    public static let tagByteCount = 16

    /// Trả `ciphertext ‖ tag`; `plaintext` rỗng → trả đúng `tagByteCount` byte (EncryptAndHash("") của Noise).
    public static func seal(_ plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        try Bytes.require(key, count: keyByteCount)
        try Bytes.require(nonce, count: nonceByteCount, isNonce: true)
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key),
                                      nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }

    /// Mở `ciphertext ‖ tag`; sai khoá, tag, AAD hoặc nonce → `CryptoError.authenticationFailed`.
    public static func open(_ ciphertextAndTag: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        try Bytes.require(key, count: keyByteCount)
        try Bytes.require(nonce, count: nonceByteCount, isNonce: true)
        guard ciphertextAndTag.count >= tagByteCount else { throw CryptoError.payloadTooShort }
        let ciphertext = ciphertextAndTag.prefix(ciphertextAndTag.count - tagByteCount)
        let tag = ciphertextAndTag.suffix(tagByteCount)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}
