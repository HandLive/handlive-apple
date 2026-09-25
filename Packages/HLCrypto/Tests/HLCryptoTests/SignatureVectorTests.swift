import Foundation
import HLProtocol
import Testing
@testable import HLCrypto

/// ed25519.json and relay-auth.json (S1.1): the vector signatures verify, ours verify, and tampered, foreign-key,
/// wrong-label, 63-byte and non-canonical (S + L) signatures are rejected (0.6.5). CryptoKit signs with a hedged
/// (randomized) nonce, so its signatures are valid RFC 8032 signatures but not byte-identical to the vectors.
@Suite("Ed25519 and relay authentication vectors")
struct SignatureVectorTests {
    @Test("ed25519.json: the vector signature and a fresh signature both verify")
    func ed25519Vectors() throws {
        let file = try VectorFile("ed25519.json")
        #expect(file.vectors.count >= 3)
        for vector in file.vectors {
            let seed = try vector.hex("seed")
            let message = try vector.hex("message")
            let publicKey = try vector.hex("public_key")
            #expect(try Ed25519.publicKey(seed: seed) == publicKey)
            #expect(Ed25519.verify(try vector.hex("signature"), message: message, publicKey: publicKey))
            let ours = try Ed25519.sign(message, seed: seed)
            #expect(ours.count == 64 && Ed25519.verify(ours, message: message, publicKey: publicKey))
            #expect(!Ed25519.verify(ours, message: message + Data([0]), publicKey: publicKey))
        }
    }

    @Test("ed25519.json: every invalid vector is rejected, including S + L and 63 bytes")
    func ed25519InvalidVectors() throws {
        let file = try VectorFile("ed25519.json")
        let reasons = Set(file.invalidVectors.compactMap { $0["reason"] as? String })
        #expect(reasons.isSuperset(of: ["signature_not_canonical", "signature_length", "message_tampered"]))
        for vector in file.invalidVectors {
            let accepted = Ed25519.verify(try vector.hex("signature"), message: try vector.hex("message"),
                                          publicKey: try vector.hex("public_key"))
            #expect(!accepted, "\(vector["name"] ?? "")")
        }
    }

    @Test("Canonical scalar check: L - 1 passes, L and L + 1 fail")
    func canonicalScalar() {
        var lMinusOne = Ed25519.groupOrder
        lMinusOne[0] -= 1
        #expect(Ed25519.isCanonicalScalar(lMinusOne))
        #expect(!Ed25519.isCanonicalScalar(Ed25519.groupOrder))
        var lPlusOne = Ed25519.groupOrder
        lPlusOne[0] += 1
        #expect(!Ed25519.isCanonicalScalar(lPlusOne))
        #expect(Ed25519.isCanonicalScalar([UInt8](repeating: 0, count: 32)))
    }

    private func request(_ vector: [String: Any]) throws -> [String: Any] {
        let text = try vector.string("request")
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }

    /// The message the relay rebuilds from a request body.
    private func signedMessage(_ vector: [String: Any], request: [String: Any]) throws -> Data {
        let deviceId = request["device_id"] as? String ?? ""
        if try vector.string("kind") == "register" {
            let key = try Base64Coding.decodeB64u(request["ik_sig_pub"] as? String ?? "")
            let ts = (request["ts"] as? NSNumber)?.int64Value ?? 0
            return try RelayAuthMessage.register(deviceId: deviceId, signingPublicKey: key,
                                                 platform: request["platform"] as? String ?? "", ts: ts)
        }
        return try RelayAuthMessage.token(challenge: try Base64Coding.decodeB64u(request["challenge"] as? String ?? ""),
                                          deviceId: deviceId)
    }

    @Test("relay-auth.json: HLREG1 and HLAUTH1 messages and signatures")
    func relayAuthVectors() throws {
        let file = try VectorFile("relay-auth.json")
        for vector in file.vectors {
            let body = try request(vector)
            let message = try signedMessage(vector, request: body)
            #expect(message == (try vector.hex("message")), "\(vector["name"] ?? "")")
            let publicKey = try vector.hex("ik_sig_pub")
            #expect(Base64Coding.encodeB64u(try vector.hex("sig")) == body["sig"] as? String)
            #expect(Ed25519.verify(try vector.hex("sig"), message: message, publicKey: publicKey))
            let ours = try Ed25519.sign(message, seed: try vector.hex("ik_sig_seed"))
            #expect(Ed25519.verify(ours, message: message, publicKey: publicKey))
            let deviceId = try vector.string("device_id")
            #expect(DeviceIdentity.matches(deviceId: deviceId, signingPublicKey: publicKey))
        }
    }

    @Test("relay-auth.json: tampered, relabelled, foreign-key, short and non-canonical signatures fail")
    func relayAuthInvalidVectors() throws {
        let file = try VectorFile("relay-auth.json")
        #expect(file.invalidVectors.count >= 10)
        for vector in file.invalidVectors {
            let body = try request(vector)
            let key = try vector.hex("ik_sig_pub")
            let signature = (try? Base64Coding.decodeB64u(body["sig"] as? String ?? "")) ?? Data()
            let message = try signedMessage(vector, request: body)
            let deviceMatches = DeviceIdentity.matches(deviceId: body["device_id"] as? String ?? "", signingPublicKey: key)
            let accepted = deviceMatches && Ed25519.verify(signature, message: message, publicKey: key)
            #expect(!accepted, "\(vector["name"] ?? "")")
        }
    }
}
