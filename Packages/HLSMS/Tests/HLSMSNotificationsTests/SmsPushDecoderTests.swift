import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLSMSNotifications

/// CONN-04 step 9b with `shared/test-vectors/push-envelope.json`: the extension decodes the vector's APNs payload into
/// an `sms/new`; locked (no key), wrong-key and stale pushes keep the generic content; repeated ids are shown once.
@Suite("Notification Service Extension decoding")
struct SmsPushDecoderTests {
    struct Fixture {
        let payload: [AnyHashable: Any]
        let prk: Data
        let ts: Int64
    }

    static func fixture() throws -> Fixture {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("shared/test-vectors/push-envelope.json")
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try #require(file["vectors"] as? [[String: Any]])
        let envelope = try #require(vectors.first { $0["kind"] as? String == "envelope" && $0["type"] as? String == "sms" })
        let pairId = try #require(envelope["pair_id"] as? String)
        let key = try #require(vectors.first { $0["kind"] as? String == "key" && $0["pair_id"] as? String == pairId })
        let prkHex = try #require(key["prk"] as? String)
        let prk = Data(stride(from: 0, to: prkHex.count, by: 2).map {
            UInt8(prkHex[prkHex.index(prkHex.startIndex, offsetBy: $0)...].prefix(2), radix: 16) ?? 0
        })
        let payloadText = try #require(envelope["apns_payload"] as? String)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [AnyHashable: Any])
        let ts = (envelope["ts"] as? NSNumber)?.int64Value ?? Int64(envelope["ts"] as? String ?? "") ?? 0
        return Fixture(payload: payload, prk: prk, ts: ts)
    }

    @Test("The vector's APNs payload decodes into its sms/new with the pair's PRK")
    func decodes() throws {
        let fixture = try Self.fixture()
        let decoded = try #require(SmsPushDecoder.decode(userInfo: fixture.payload, nowMs: fixture.ts + 1000) { _ in
            fixture.prk
        })
        #expect(decoded.new.message.messageKey == "sms:12847" && decoded.new.message.body == "Nhớ mang theo tài liệu")
        #expect(decoded.pairId == fixture.payload["p"] as? String)
    }

    @Test("Locked (no key), another pair's key or more than 24 h: generic content")
    func generic() throws {
        let fixture = try Self.fixture()
        #expect(SmsPushDecoder.decode(userInfo: fixture.payload, nowMs: fixture.ts) { _ in nil } == nil)
        #expect(SmsPushDecoder.decode(userInfo: fixture.payload, nowMs: fixture.ts) { _ in Data(repeating: 1, count: 32) }
                == nil)
        #expect(SmsPushDecoder.decode(userInfo: fixture.payload, nowMs: fixture.ts + PushEnvelope.maxAgeMs + 1) { _ in
            fixture.prk
        } == nil)
        #expect(SmsPushDecoder.decode(userInfo: ["aps": [:]], nowMs: 0) { _ in fixture.prk } == nil)
    }

    @Test("A repeated envelope id is shown once; ids older than 24 h are forgotten")
    func deduplication() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("push-ids-\(UUID().uuidString).json")
        let dedup = PushDeduplicator(fileURL: url)
        #expect(dedup.firstSighting(of: "0192f3e4-7a10-7b20-8c30-9d40ae50bf60", nowMs: 1_000))
        #expect(!dedup.firstSighting(of: "0192f3e4-7a10-7b20-8c30-9d40ae50bf60", nowMs: 2_000))
        #expect(dedup.firstSighting(of: "0192f3e4-7a10-7b20-8c30-9d40ae50bf60", nowMs: 1_000 + PushEnvelope.maxAgeMs + 1))
    }
}
