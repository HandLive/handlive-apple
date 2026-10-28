import Foundation
import Testing
@testable import HLCrypto

/// shared/test-vectors/bt-link.json kind "handshake": `Noise_NNpsk0_25519_ChaChaPoly_SHA256` phía C (0.4.5 bước
/// 1-4). Vector không phải vector công bố của tài liệu Noise (xem mô tả file) — rà soát riêng ở #3418/#3431/#3432
/// (Trang, Huy) bằng thư viện `noiseprotocol` thật, nên đáng tin làm điểm neo cho cổng vào của HandLive.
@Suite("Noise_NNpsk0 initiator (0.4.5, bt-link.json)")
struct NoiseNNpsk0Tests {
    static func handshakeVectors() throws -> [[String: Any]] {
        try VectorFile("bt-link.json").vectors.filter { $0["kind"] as? String == "handshake" }
    }

    @Test("firstMessage and tryOpenSecondMessage match the vector")
    func message1AndMessage2MatchVector() throws {
        let vectors = try Self.handshakeVectors()
        #expect(vectors.count == 1)
        for vector in vectors {
            let prologue = NoiseNNpsk0.prologue(nS: try vector.hex("n_s"))
            #expect(prologue == (try vector.hex("prologue")), "\(vector.label)")
            let built = try NoiseNNpsk0.firstMessage(psk: try vector.hex("psk"), prologue: prologue,
                                                     ephemeralPrivateKey: try vector.hex("e_priv_c"))
            #expect(built.message1 == (try vector.hex("message1")), "\(vector.label)")
            let message2 = try vector.hex("e_pub_s") + vector.hex("ciphertext_tag_2")
            let keys = try #require(NoiseNNpsk0.tryOpenSecondMessage(built, ephemeralPrivateKey: vector.hex("e_priv_c"),
                                                                     message2: message2), "\(vector.label)")
            #expect(keys.c1 == (try vector.hex("c1")), "\(vector.label)")
            #expect(keys.c2 == (try vector.hex("c2")), "\(vector.label)")
        }
    }

    @Test("a tampered noise2 tag never verifies")
    func tamperedNoise2TagNeverVerifies() throws {
        let vector = try #require(VectorFile("bt-link.json").invalidVectors.first { $0["reason"] as? String == "tag_mismatch_noise2" })
        let handshake = try #require(Self.handshakeVectors().first { ($0["name"] as? String)?.contains("cặp 1") == true })
        let prologue = NoiseNNpsk0.prologue(nS: try handshake.hex("n_s"))
        let built = try NoiseNNpsk0.firstMessage(psk: try handshake.hex("psk"), prologue: prologue,
                                                 ephemeralPrivateKey: try handshake.hex("e_priv_c"))
        let message2 = try vector.hex("e_pub_s") + vector.hex("ciphertext_tag_2")
        #expect(NoiseNNpsk0.tryOpenSecondMessage(built, ephemeralPrivateKey: try handshake.hex("e_priv_c"),
                                                 message2: message2) == nil)
    }

    @Test("Rekey() changes the key deterministically")
    func rekeyIsDeterministic() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let rekeyed = try NoiseNNpsk0.rekey(key)
        #expect(rekeyed.count == 32)
        #expect(rekeyed != key)
        #expect(try NoiseNNpsk0.rekey(key) == rekeyed)
    }
}
