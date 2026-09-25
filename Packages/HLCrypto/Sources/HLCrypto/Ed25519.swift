import CryptoKit
import Foundation

/// Ed25519 (RFC 8032) cho `ik_sig`: khóa riêng là seed 32 byte.
public enum Ed25519 {
    public static func generateSeed() -> Data {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }

    public static func publicKey(seed: Data) throws -> Data {
        try Bytes.require(seed, count: 32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    }

    public static func sign(_ message: Data, seed: Data) throws -> Data {
        try Bytes.require(seed, count: 32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
    }

    public static func verify(_ signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
