import CryptoKit
import Foundation

/// Ed25519 (RFC 8032) for `ik_sig`: the private key is the 32-byte seed.
public enum Ed25519 {
    public static let signatureByteCount = 64
    public static let publicKeyByteCount = 32

    /// Group order L = 2^252 + 27742317777372353535851937790883648493, little-endian (RFC 8032 §5.1).
    static let groupOrder: [UInt8] = [
        0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]

    public static func generateSeed() -> Data {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }

    public static func publicKey(seed: Data) throws -> Data {
        try Bytes.require(seed, count: 32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    }

    /// Deterministic signature `R ‖ S` (64 bytes).
    public static func sign(_ message: Data, seed: Data) throws -> Data {
        try Bytes.require(seed, count: 32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
    }

    /// Strict verification (00-common-specs 0.6.5): exactly 64 bytes, a 32-byte key, and a canonical `S < L`
    /// (RFC 8032 §5.1.7) checked here rather than left to the library, before the signature itself.
    public static func verify(_ signature: Data, message: Data, publicKey: Data) -> Bool {
        guard signature.count == signatureByteCount, publicKey.count == publicKeyByteCount,
              isCanonicalScalar([UInt8](signature.suffix(32))),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// `S < L` for a 32-byte little-endian scalar.
    static func isCanonicalScalar(_ scalar: [UInt8]) -> Bool {
        guard scalar.count == 32 else { return false }
        for index in stride(from: 31, through: 0, by: -1) where scalar[index] != groupOrder[index] {
            return scalar[index] < groupOrder[index]
        }
        return false // S == L
    }
}
