import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// Phía C của 0.4.5 bước 1-4 qua "ống giả": một kênh giả lập chỉ truyền byte đã dựng sẵn từ bt-link.json (không
/// đụng radio, M7.1c lo việc đó) — đúng tinh thần "fake pipe" của thẻ M7.1b.
@Suite("Bluetooth link-security client over a fake pipe (0.4.5)")
struct BluetoothLinkSecurityClientTests {
    static func handshake() throws -> [String: Any] {
        try #require(VectorFile("bt-link.json").vectors
            .first { $0["kind"] as? String == "handshake" && ($0["name"] as? String)?.contains("cặp 1") == true })
    }

    /// `*_record` của bt-link.json là bản ghi dây thật: `rlen` (2 byte, `BtRecordCodec`) ‖ thân (kind ‖ payload,
    /// `BtPreauthRecord`); `BluetoothLinkSecurityClient` làm việc ở lớp thân, không lo rlen (lớp đó thuộc M7.1c).
    static func body(ofRecord record: Data) -> Data {
        let body = record.dropFirst(BtRecordCodec.lengthPrefixSize)
        precondition(BtRecordCodec.decodeRlen(record.prefix(BtRecordCodec.lengthPrefixSize)) == body.count)
        return Data(body)
    }

    @Test("a full handshake over the challenge/noise1/noise2 records matches the vector")
    func fullHandshakeMatchesVector() throws {
        let handshake = try Self.handshake()
        let client = BluetoothLinkSecurityClient(generateEphemeralPrivateKey: { try! handshake.hex("e_priv_c") })

        let challengeBody = try Self.body(ofRecord: handshake.hex("challenge_record"))
        let decodedChallenge = try BtPreauthRecord.decode(challengeBody)
        #expect(decodedChallenge.kind == BtPreauthRecord.kindChallenge)
        client.receiveChallenge(nS: decodedChallenge.payload)

        let noise1Body = try client.buildNoise1(psk: try handshake.hex("psk"))
        #expect(noise1Body == (try Self.body(ofRecord: handshake.hex("noise1_record"))))

        let noise2Body = try Self.body(ofRecord: handshake.hex("noise2_record"))
        let decodedNoise2 = try BtPreauthRecord.decode(noise2Body)
        #expect(decodedNoise2.kind == BtPreauthRecord.kindNoise2)
        let keys = try #require(client.receiveNoise2(message2: decodedNoise2.payload))
        #expect(keys.c1 == (try handshake.hex("c1")))
        #expect(keys.c2 == (try handshake.hex("c2")))
    }

    @Test("a tampered noise2 tag is rejected, not thrown")
    func tamperedNoise2TagIsRejected() throws {
        let handshake = try Self.handshake()
        let invalid = try #require(VectorFile("bt-link.json").invalidVectors.first { $0["reason"] as? String == "tag_mismatch_noise2" })
        let client = BluetoothLinkSecurityClient(generateEphemeralPrivateKey: { try! handshake.hex("e_priv_c") })
        client.receiveChallenge(nS: try handshake.hex("n_s"))
        _ = try client.buildNoise1(psk: try handshake.hex("psk"))

        let message2 = try invalid.hex("e_pub_s") + invalid.hex("ciphertext_tag_2")
        #expect(client.receiveNoise2(message2: message2) == nil)
    }

    @Test("a fresh challenge changes noise1, so a recorded one from another channel never reapplies")
    func aFreshChallengeChangesNoise1() throws {
        let handshake = try Self.handshake()
        let replayed = try #require(VectorFile("bt-link.json").invalidVectors.first { $0["reason"] as? String == "replayed_channel" })
        let client = BluetoothLinkSecurityClient(generateEphemeralPrivateKey: { try! handshake.hex("e_priv_c") })

        // n_s của kênh mới (challenge khác) — noise1 dựng lại dưới prologue mới khác hẳn bản ghi của kênh cũ.
        client.receiveChallenge(nS: try replayed.hex("n_s"))
        let noise1Body = try client.buildNoise1(psk: try handshake.hex("psk"))
        #expect(noise1Body != (try Self.body(ofRecord: handshake.hex("noise1_record"))))
    }
}
