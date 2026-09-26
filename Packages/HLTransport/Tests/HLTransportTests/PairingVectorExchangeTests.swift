import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// The client's exchange against the vector's phone messages, and its refusals of the negative vectors.
@Suite("PAIR-01 handshake vectors: the client exchange")
struct PairingVectorExchangeTests {
    /// Replays the vector's `pair/offer` and `pair/done` and returns what the client sent.
    private static func phone(_ channel: InMemoryChannel, offer: String, done: String) async throws -> (String, String) {
        guard case .text(let hello) = try await channel.receive() else { throw VectorError.missing("hello") }
        try await channel.send(.text(offer))
        guard case .text(let confirm) = try await channel.receive() else { throw VectorError.missing("confirm") }
        try await channel.send(.text(done))
        _ = try? await channel.receive()
        return (hello, confirm)
    }

    @Test("Hello, confirm and the stored result match the vector; the client closes with 1000")
    func exchange() async throws {
        for vector in try PairingVectorTests.file().vectors {
            let name = vector.label
            let (client, phoneEnd) = InMemoryChannel.pair()
            let offer = try vector.string("offer_envelope"), done = try vector.string("done_envelope")
            let replay = Task { try await Self.phone(phoneEnd, offer: offer, done: done) }
            let createdAt = try vector.int("created_at")
            let result = try await PairingVectorTests.exchange(vector)
                .run(over: client, certificateSHA256: try vector.hex("tls_sha256"), now: { createdAt })
            let (hello, confirm) = try await replay.value
            let expectedHello = try PairingVectorTests.data(plaintext: try vector.string("hello_plaintext"))
            #expect(try PairingVectorTests.data(envelope: hello) == expectedHello, "\(name)")
            let sent = try PairingVectorTests.data(envelope: confirm)
            let expected = try PairingVectorTests.data(plaintext: try vector.string("confirm_plaintext"))
            for key in ["pair_id", "created_at", "prk_check"] {
                #expect(sent[key] as? NSObject == expected[key] as? NSObject, "\(name) \(key)")
            }
            try checkOwnSignature(sent, vector: vector)
            let expectedResult = [try vector.string("pair_id"), String(createdAt), try vector.string("prk"),
                                  try vector.string("attestation"), try vector.string("sig_s"), try vector.string("tls_sha256"),
                                  try vector.string("android_name"), try vector.string("android_device_id")]
            let actual = [result.pairId, String(result.createdAt), Hex.encode(result.prk), Hex.encode(result.attestation),
                          Hex.encode(result.signaturePeer), Hex.encode(result.certificateSHA256), result.phoneName,
                          result.phoneDeviceId]
            #expect(actual == expectedResult, "\(name)")
            #expect(phoneEnd.receivedCloseCode == .normal, "\(name)")
        }
    }

    /// Our `sig` verifies over the vector's attestation and our `mac` covers exactly it.
    private func checkOwnSignature(_ sent: NSDictionary, vector: [String: Any]) throws {
        let signature = try Base64Coding.decodeB64u(try #require(sent["sig"] as? String))
        let attestation = try vector.hex("attestation")
        let clientKey = try vector.hex("client_ik_sig_pub")
        #expect(Ed25519.verify(signature, message: attestation, publicKey: clientKey), "\(vector.label)")
        let authKey = try vector.hex("k_pa")
        let mac = try PairingAuthDerivation.confirmMac(authKey: authKey, transcript: try vector.hex("t_offer"),
                                                       pairId: try vector.string("pair_id"),
                                                       createdAt: try vector.int("created_at"), clientSignature: signature)
        #expect(Base64Coding.encodeB64u(mac) == sent["mac"] as? String, "\(vector.label)")
    }

    @Test("Every negative the client checks fails exactly at its check with its pair/error code")
    func negatives() async throws {
        let file = try PairingVectorTests.file()
        let vectors = Dictionary(uniqueKeysWithValues: try file.vectors.map { (try $0.string("name"), $0) })
        let clientSide = file.invalidVectors.filter { ["client", "both"].contains($0["checked_by"] as? String) }
        var checked = 0
        for negative in clientSide {
            let vector = try #require(vectors[try negative.string("vector")])
            switch try negative.string("check") {
            case "offer_mac":
                try await checkOfferRefusal(negative, vector: vector)
            case "done_mac", "prk_check_s", "sig_s":
                try await checkDoneRefusal(negative, vector: vector)
            case "k_pin":
                break // PairingVectorTests.pinKey compares against both values
            case "pr":
                let pr = PairingAuthDerivation.pairingRequestHint(clientDHPublicKey: try vector.hex("client_ik_dh_pub"))
                #expect(pr != (try negative.string("pr")), "\(negative.label)")
            default:
                Issue.record("unknown client check in \(negative.label)")
            }
            checked += 1
        }
        #expect(checked == clientSide.count && checked == 13)
    }

    private func checkOfferRefusal(_ negative: [String: Any], vector: [String: Any]) async throws {
        let offer = try PairingVectorTests.decode(PairOfferData.self, envelope: try negative.string("envelope"))
        // A wrong PIN fails at the MAC whatever the Argon2 cost; small parameters keep the test fast.
        let exchange = try PairingVectorTests.exchange(vector, pinParameters: Argon2id.Parameters(passes: 1, memoryKiB: 64,
                                                                                                  lanes: 4, tagLength: 32))
        do {
            _ = try await exchange.checkOffer(offer, clientNonce: try vector.hex("nonce_c"),
                                              certificateSHA256: try vector.hex("tls_sha256"))
            Issue.record("accepted \(negative.label)")
        } catch let refusal as PairingRefusal {
            let expectedError = try negative.string("expected_error")
            #expect(refusal.check == .offerMac && refusal.code.rawValue == expectedError, "\(negative.label)")
            if let reply = negative["client_reply_plaintext"] as? String {
                let error = PairErrorData(code: refusal.code, message: refusal.message,
                                          attemptsLeft: refusal.attemptsLeft.map(Int32.init))
                let encoded = try TypedPayload(op: "error", data: error).encoded()
                let ours = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
                #expect(ours?["data"] as? NSDictionary == (try PairingVectorTests.data(plaintext: reply)), "\(negative.label)")
            }
        }
    }

    private func checkDoneRefusal(_ negative: [String: Any], vector: [String: Any]) async throws {
        let exchange = try PairingVectorTests.exchange(vector)
        let offer = try PairingVectorTests.decode(PairOfferData.self, envelope: try vector.string("offer_envelope"))
        let accepted = try await exchange.checkOffer(offer, clientNonce: try vector.hex("nonce_c"),
                                                     certificateSHA256: try vector.hex("tls_sha256"))
        let confirm = try accepted.confirm(identity: exchange.identity, createdAt: try vector.int("created_at"),
                                           pairId: try vector.string("pair_id"))
        let done = try PairingVectorTests.decode(PairDoneData.self, envelope: try negative.string("envelope"))
        do {
            _ = try accepted.finish(done, confirm: confirm, identity: exchange.identity)
            Issue.record("accepted \(negative.label)")
        } catch let refusal as PairingRefusal {
            let check = try negative.string("check")
            #expect(refusal.check.rawValue == check && refusal.code == .authFailed, "\(negative.label)")
        }
    }
}
