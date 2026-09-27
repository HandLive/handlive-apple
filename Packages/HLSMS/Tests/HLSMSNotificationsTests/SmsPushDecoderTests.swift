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

    @Test("Every sms/new vector opens, the cut ones too: body and snippet keep their lengths, hl stays ≤ 3,000")
    func everySmsVector() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("shared/test-vectors/push-envelope.json")
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try #require(file["vectors"] as? [[String: Any]])
        var prks: [String: Data] = [:]
        for key in vectors where key["kind"] as? String == "key" {
            let hex = try #require(key["prk"] as? String)
            prks[try #require(key["pair_id"] as? String)] = Data(stride(from: 0, to: hex.count, by: 2).map {
                UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16) ?? 0
            })
        }
        let sms = vectors.filter { $0["kind"] as? String == "envelope" && $0["type"] as? String == "sms" }
        #expect(sms.count == 7)
        for vector in sms {
            let name = vector["name"] as? String ?? "?"
            let payloadText = try #require(vector["apns_payload"] as? String)
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(payloadText.utf8))
                as? [AnyHashable: Any])
            let aps = try #require(payload["aps"] as? [String: Any])
            #expect(aps["thread-id"] as? String == "sms", "\(name)") // generic until the extension decrypts
            let ts = (vector["ts"] as? NSNumber)?.int64Value ?? 0
            let decoded = try #require(SmsPushDecoder.decode(userInfo: payload, nowMs: ts + 1000) { prks[$0] }, "\(name)")
            let plaintext = try #require(vector["plaintext"] as? String)
            let expected = try HLJSON.decode(Payload.self, from: Data(plaintext.utf8)).decodeData(as: SmsNewData.self)
            #expect(decoded.new == expected, "\(name)")
            let content = SmsNotificationBuilder.content(for: decoded.new, pairId: decoded.pairId, simLabel: nil,
                                                         showPreview: true)
            #expect(content.threadIdentifier == "sms:\(decoded.pairId):\(expected.thread.threadId)", "\(name)")
            #expect(content.categoryIdentifier == (expected.thread.addresses.count > 1 ? SmsNotificationKeys.groupCategory
                : SmsNotificationKeys.category), "\(name)")
            #expect(content.body == expected.message.body, "\(name)")
            guard let cut = vector["truncation"] as? [String: Any] else { continue }
            let hl = try #require(payload["hl"] as? String)
            #expect(hl.count == (cut["env_b64_length"] as? Int) && hl.count <= 3000, "\(name)")
            #expect(decoded.new.message.body.unicodeScalars.count == cut["body_code_points"] as? Int, "\(name)")
            #expect(decoded.new.message.body.utf16.count == cut["body_utf16_units"] as? Int, "\(name)")
            #expect(decoded.new.thread.snippet.unicodeScalars.count == cut["snippet_code_points"] as? Int, "\(name)")
        }
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
