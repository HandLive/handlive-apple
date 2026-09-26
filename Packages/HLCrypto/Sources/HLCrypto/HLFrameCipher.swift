import Foundation
import HLProtocol

/// Mã hóa khung HL (0.5.2): AAD = 11 byte header.
public enum HLFrameCipher {
    public static func seal(header: HLFrameHeader, plaintext: Data, key: Data,
                            nonce: Data = XChaCha20Poly1305.randomNonce()) throws -> Data {
        let sealed = try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce, aad: header.bytes)
        return HLFrame(header: header, encrypted: sealed.combined).bytes
    }

    public static func open(_ frame: Data, key: Data) throws -> (header: HLFrameHeader, plaintext: Data) {
        let parsed = try HLFrame.parse(frame)
        let plaintext = try XChaCha20Poly1305.open(combined: parsed.encrypted, key: key, aad: parsed.header.bytes)
        return (parsed.header, plaintext)
    }
}
