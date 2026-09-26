import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// shared/test-vectors/pair-handshake.json (PAIR-01, card S1.3): the client side reproduces every derivation, sends the
/// vector's hello and confirm, accepts its offer and done, and refuses every client-checked negative at its `check`.
/// Ed25519 signing in CryptoKit is randomized (hedged), so `sig_c` is verified rather than reproduced byte for byte.
@Suite("PAIR-01 handshake vectors (pair-handshake.json)")
struct PairingVectorTests {
    static func file() throws -> VectorFile {
        try VectorFile("pair-handshake.json")
    }

    static func identity(_ vector: [String: Any]) throws -> PairingIdentity {
        PairingIdentity(deviceId: try vector.string("client_device_id"), name: try vector.string("client_name"),
                        platform: CapabilityData.Platform(rawValue: try vector.string("client_platform")) ?? .macos,
                        model: vector["client_model"] as? String, signingSeed: try vector.hex("client_ik_sig_seed"),
                        signingPublicKey: try vector.hex("client_ik_sig_pub"), dhPrivateKey: try vector.hex("client_ik_dh_priv"),
                        dhPublicKey: try vector.hex("client_ik_dh_pub"))
    }

    static func credential(_ vector: [String: Any], attemptsLeft: Int = 3) throws -> PairingCredential {
        try vector.string("mode") == "qr" ? .qr(secret: try vector.hex("pairing_secret"))
            : .pin(try vector.string("pin"), attemptsLeft: attemptsLeft)
    }

    static func exchange(_ vector: [String: Any], pinParameters: Argon2id.Parameters = .pairingPIN,
                         attemptsLeft: Int = 3) throws -> PairingExchange {
        var exchange = PairingExchange(identity: try identity(vector),
                                       credential: try credential(vector, attemptsLeft: attemptsLeft), offerTimeout: .seconds(30))
        exchange.pinParameters = pinParameters
        let nonce = try vector.hex("nonce_c")
        let pairId = try vector.string("pair_id")
        exchange.makeNonce = { nonce }
        exchange.makePairId = { pairId }
        return exchange
    }

    /// `data` of a `pair` envelope or plaintext as a JSON object, for order-independent comparison.
    static func data(envelope: String) throws -> NSDictionary {
        let plaintext = try Envelope.parse(Data(envelope.utf8)).payloadBytes
        return try data(plaintext: String(bytes: plaintext, encoding: .utf8) ?? "")
    }

    static func data(plaintext: String) throws -> NSDictionary {
        let object = try JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any]
        return try #require(object?["data"] as? NSDictionary)
    }

    static func decode<Body: Decodable>(_ type: Body.Type, envelope: String) throws -> Body {
        try Payload.parse(Envelope.parse(Data(envelope.utf8)).payloadBytes).decodeData(as: type)
    }

    @Test("Keys, QR URI and pr, K_pa, T_offer, MACs, attestation, Security Code, PRK and prk_check of every vector")
    func derivations() throws {
        let vectors = try Self.file().vectors
        #expect(vectors.count == 3)
        for vector in vectors {
            let name = vector.label
            let identity = try Self.identity(vector)
            #expect(try Ed25519.publicKey(seed: identity.signingSeed) == identity.signingPublicKey, "\(name)")
            #expect(try X25519.publicKey(privateKey: identity.dhPrivateKey) == identity.dhPublicKey, "\(name)")
            #expect(DeviceIdentity.matches(deviceId: identity.deviceId, signingPublicKey: identity.signingPublicKey))
            #expect(PairingInvite.fittedName(identity.name) == identity.name, "\(name)")
            if try vector.string("mode") == "qr" {
                let rendezvous = (vector["qr_rv"] as? String).flatMap { try? Hex.decode($0) }
                let uri = PairingInvite.uri(clientDHPublicKey: identity.dhPublicKey,
                                            pairingSecret: try vector.hex("pairing_secret"), name: identity.name,
                                            rendezvous: rendezvous)
                #expect(uri == (try vector.string("qr_uri")), "\(name)")
                let pr = try vector.string("pr")
                #expect(PairingAuthDerivation.pairingRequestHint(clientDHPublicKey: identity.dhPublicKey) == pr)
            }
            try checkDerivations(vector, identity: identity)
        }
    }

    private func checkDerivations(_ vector: [String: Any], identity: PairingIdentity) throws {
        let name = vector.label
        let nonceC = try vector.hex("nonce_c"), nonceS = try vector.hex("nonce_s")
        let secret = try vector.hex("secret")
        let authKey = PairingAuthDerivation.authKey(secret: secret, clientNonce: nonceC, serverNonce: nonceS)
        #expect(Hex.encode(authKey) == (try vector.string("k_pa")), "\(name)")
        let androidId = try vector.string("android_device_id")
        let androidSig = try vector.hex("android_ik_sig_pub")
        let transcript = try PairingAuthDerivation.offerTranscript(
            client: PairingParty(deviceId: identity.deviceId, nonce: nonceC, signingPublicKey: identity.signingPublicKey,
                                 dhPublicKey: identity.dhPublicKey, name: identity.name),
            server: PairingParty(deviceId: androidId, nonce: nonceS, signingPublicKey: androidSig,
                                 dhPublicKey: try vector.hex("android_ik_dh_pub"), name: try vector.string("android_name")),
            tlsSHA256: try vector.hex("tls_sha256"))
        #expect(Hex.encode(transcript) == (try vector.string("t_offer")), "\(name)")
        let offerMac = try vector.string("offer_mac")
        #expect(Hex.encode(PairingAuthDerivation.offerMac(authKey: authKey, transcript: transcript)) == offerMac)
        let pairId = try vector.string("pair_id"), createdAt = try vector.int("created_at")
        let attestation = try PairingAuthDerivation.attestation(PairingAttestationFields(
            pairId: pairId, androidDeviceId: androidId, clientDeviceId: identity.deviceId, androidSigningKey: androidSig,
            clientSigningKey: identity.signingPublicKey, createdAt: createdAt))
        #expect(Hex.encode(attestation) == (try vector.string("attestation")), "\(name)")
        #expect(Hex.encode(HMACSHA256.sha256(attestation).prefix(4)) == (try vector.string("security_code")))
        let sigC = try vector.hex("sig_c"), sigS = try vector.hex("sig_s")
        #expect(Ed25519.verify(sigC, message: attestation, publicKey: identity.signingPublicKey), "\(name)")
        #expect(Ed25519.verify(sigS, message: attestation, publicKey: androidSig), "\(name)")
        let ours = try Ed25519.sign(attestation, seed: identity.signingSeed)
        #expect(Ed25519.verify(ours, message: attestation, publicKey: identity.signingPublicKey))
        #expect(Hex.encode(try PairingAuthDerivation.confirmMac(authKey: authKey, transcript: transcript, pairId: pairId,
                                                                createdAt: createdAt, clientSignature: sigC))
            == (try vector.string("confirm_mac")), "\(name)")
        #expect(Hex.encode(try PairingAuthDerivation.doneMac(authKey: authKey, pairId: pairId, serverSignature: sigS))
            == (try vector.string("done_mac")), "\(name)")
        let prk = try PairingKeyDerivation.prk(ownDHPrivateKey: identity.dhPrivateKey,
                                               peerDHPublicKey: try vector.hex("android_ik_dh_pub"), pairingSecret: secret,
                                               ownDeviceId: identity.deviceId, peerDeviceId: androidId)
        #expect(Hex.encode(prk) == (try vector.string("prk")), "\(name)")
        #expect(Hex.encode(try PairingAuthDerivation.prkCheck(prk: prk, pairId: pairId, role: .client))
            == (try vector.string("prk_check_c")))
        #expect(Hex.encode(try PairingAuthDerivation.prkCheck(prk: prk, pairId: pairId, role: .server))
            == (try vector.string("prk_check_s")))
    }

    @Test("K_pin of the PIN vector (Argon2id v0x13, 64 MiB, p = 4) differs from p = 1 and from an integer PIN")
    func pinKey() throws {
        let file = try Self.file()
        let vector = try #require(file.vectors.first { $0["mode"] as? String == "pin" })
        let key = PairingAuthDerivation.pinKey(pin: try vector.string("pin"), clientNonce: try vector.hex("nonce_c"),
                                               serverNonce: try vector.hex("nonce_s"))
        let expectedKey = try vector.string("k_pin")
        let secret = try vector.hex("secret")
        #expect(Hex.encode(key) == expectedKey && key == secret)
        let negatives = file.invalidVectors.filter { $0["check"] as? String == "k_pin" }
        #expect(negatives.count == 2)
        for negative in negatives {
            #expect(Hex.encode(key) != (try negative.string("k_pin_used")), "\(negative.label)")
        }
    }
}
