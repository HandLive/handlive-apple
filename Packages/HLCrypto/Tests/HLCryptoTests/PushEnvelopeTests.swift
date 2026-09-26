import CryptoKit
import Foundation
import HLProtocol
import Testing
@testable import HLCrypto

/// `K_push` (0.6.1) and the envelope of an APNs alert (0.4.4, CONN-04 API 4, E5, E7).
@Suite("K_push and push envelopes")
struct PushEnvelopeTests {
    static let prk = Data((0..<32).map { UInt8($0) })

    @Test("K_push is HKDF-SHA256(PRK, empty salt, info handlive/v1/push, 32 bytes) and differs from K_disc")
    func key() throws {
        let expected = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Self.prk), salt: Data(),
                                              info: Data("handlive/v1/push".utf8), outputByteCount: 32)
        let key = try PushEnvelope.key(prk: Self.prk)
        #expect(key == expected.withUnsafeBytes { Data($0) })
        #expect(key != (try DiscoveryHint.key(prk: Self.prk)))
        #expect(throws: (any Error).self) { try PushEnvelope.key(prk: Data(count: 16)) }
    }

    @Test("A sealed sms/new opens with the same PRK within 24 h")
    func roundTrip() throws {
        let plaintext = Data(#"{"op":"new","data":{}}"#.utf8)
        let envelope = try PushEnvelope.seal(type: .sms, plaintext: plaintext, prk: Self.prk, ts: 1_727_150_060_456)
        #expect(try PushEnvelope.open(envelope, prk: Self.prk, nowMs: 1_727_150_060_456 + 1000) == plaintext)
        #expect(try PushEnvelope.open(envelope, prk: Self.prk, nowMs: 1_727_150_060_456 + PushEnvelope.maxAgeMs)
                == plaintext)
    }

    @Test("Older than 24 h, another pair's key or a changed header are refused")
    func refusals() throws {
        let envelope = try PushEnvelope.seal(type: .sms, plaintext: Data("{}".utf8), prk: Self.prk, ts: 1_000)
        #expect(throws: PushEnvelope.OpenError.expired) {
            try PushEnvelope.open(envelope, prk: Self.prk, nowMs: 1_000 + PushEnvelope.maxAgeMs + 1)
        }
        #expect(throws: PushEnvelope.OpenError.undecryptable) {
            try PushEnvelope.open(envelope, prk: Data(repeating: 1, count: 32), nowMs: 2_000)
        }
        let moved = Envelope(type: .callEvent, id: envelope.id, ts: envelope.ts, payload: envelope.payload)
        #expect(throws: PushEnvelope.OpenError.undecryptable) { try PushEnvelope.open(moved, prk: Self.prk, nowMs: 2_000) }
    }
}
