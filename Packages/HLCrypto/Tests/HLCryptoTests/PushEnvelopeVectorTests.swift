import Foundation
import HLProtocol
import Testing
@testable import HLCrypto

/// `shared/test-vectors/push-envelope.json` (S2.3): `K_push` of each pair and the envelopes an iPhone/iPad receives in
/// `hl`, decrypted as the Notification Service Extension does (CONN-04 step 9b); every invalid vector is refused.
@Suite("push-envelope.json")
struct PushEnvelopeVectorTests {
    let file: VectorFile
    let prkByPair: [String: Data]

    init() throws {
        file = try VectorFile("push-envelope.json")
        var prks: [String: Data] = [:]
        for vector in file.vectors where vector["kind"] as? String == "key" {
            prks[try vector.string("pair_id")] = try vector.hex("prk")
        }
        prkByPair = prks
    }

    @Test("K_push of every pair")
    func keys() throws {
        for vector in file.vectors where vector["kind"] as? String == "key" {
            let expected = try vector.hex("k_push")
            #expect(try PushEnvelope.key(prk: try vector.hex("prk")) == expected, "\(vector.label)")
        }
    }

    @Test("The APNs payload's p and hl open to the plaintext with the pair's K_push")
    func envelopes() throws {
        for vector in file.vectors where vector["kind"] as? String == "envelope" {
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(try vector.string("apns_payload").utf8))
                as? [String: Any])
            let fields = try #require(PushAlertFields(userInfo: payload), "\(vector.label)")
            let pairId = try vector.string("pair_id")
            let envB64 = try vector.string("env_b64")
            #expect(fields.pairId == pairId && (payload["hl"] as? String) == envB64)
            let prk = try #require(prkByPair[fields.pairId])
            let ts = fields.envelope.ts
            let plaintext = try PushEnvelope.open(fields.envelope, prk: prk, nowMs: ts + 1000)
            let expected = try vector.string("plaintext")
            #expect(String(bytes: plaintext, encoding: .utf8) == expected, "\(vector.label)")
        }
    }

    @Test("Wrong key, changed tag or header, a stale envelope and base64url are all refused")
    func invalid() throws {
        #expect(file.invalidVectors.count == 9)
        for vector in file.invalidVectors {
            let userInfo: [AnyHashable: Any] = ["p": try vector.string("pair_id"), "hl": try vector.string("env_b64")]
            let reason = vector["reason"] as? String
            guard let fields = PushAlertFields(userInfo: userInfo) else {
                #expect(reason == "not_b64", "\(vector.label)")
                continue
            }
            let prk = try #require(prkByPair[fields.pairId])
            switch reason {
            case "wrong_key":
                // The key a careless receiver would use (another pair's K_push, the PRK itself, K_disc) cannot open it.
                let key = try vector.hex("key")
                #expect(key != (try PushEnvelope.key(prk: prk)), "\(vector.label)")
                #expect(throws: (any Error).self, "\(vector.label)") { try EnvelopeCipher.open(fields.envelope, key: key) }
            case "stale":
                let received = try #require((vector["received_at_ms"] as? NSNumber)?.int64Value
                    ?? (vector["received_at_ms"] as? String).flatMap(Int64.init))
                #expect(throws: PushEnvelope.OpenError.expired, "\(vector.label)") {
                    try PushEnvelope.open(fields.envelope, prk: prk, nowMs: received)
                }
            default:
                #expect(throws: PushEnvelope.OpenError.undecryptable, "\(vector.label)") {
                    try PushEnvelope.open(fields.envelope, prk: prk, nowMs: fields.envelope.ts + 1000)
                }
            }
        }
    }
}
