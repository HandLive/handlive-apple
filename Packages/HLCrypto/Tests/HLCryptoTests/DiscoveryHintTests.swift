import Foundation
import Testing
@testable import HLCrypto

/// shared/test-vectors/discovery-hint.json: `K_disc`, the hint of each hour, the three-hour window of the client and
/// the TXT `h` it must and must not match (0.4.1, CONN-01 step 3).
@Suite("mDNS discovery hint (0.4.1, discovery-hint.json)")
struct DiscoveryHintTests {
    static func file() throws -> VectorFile {
        try VectorFile("discovery-hint.json")
    }

    /// `prk` of each pair, from the `key` vectors.
    static func prks(_ file: VectorFile) throws -> [String: Data] {
        var prks: [String: Data] = [:]
        for vector in file.vectors where vector["kind"] as? String == "key" {
            prks[try vector.string("name")] = try vector.hex("prk")
        }
        return prks
    }

    @Test("K_disc, the message and hint of every hour, and the hint advertised and accepted at each clock value")
    func keyVectors() throws {
        let keyVectors = try Self.file().vectors.filter { $0["kind"] as? String == "key" }
        #expect(keyVectors.count == 2)
        for vector in keyVectors {
            let prk = try vector.hex("prk")
            let key = try DiscoveryHint.key(prk: prk)
            #expect(Hex.encode(key) == (try vector.string("k_disc")), "\(vector.label)")
            for hour in vector["hours"] as? [[String: Any]] ?? [] {
                let index = try hour.int("hour")
                var message = DiscoveryHint.label
                withUnsafeBytes(of: index.bigEndian) { message.append(contentsOf: $0) }
                #expect(Hex.encode(message) == (try hour.string("message")), "\(vector.label) hour \(index)")
                #expect(DiscoveryHint.hint(discoveryKey: key, hour: index) == (try hour.string("hint")))
            }
            for clock in vector["clock"] as? [[String: Any]] ?? [] {
                let now = try clock.int("now_ms")
                let hour = DiscoveryHint.hourIndex(nowMs: now)
                #expect(hour == (try clock.int("hour")), "\(vector.label) at \(now)")
                #expect(DiscoveryHint.hint(discoveryKey: key, hour: hour) == (try clock.string("advertised")))
                #expect(try DiscoveryHint.acceptedHints(prk: prk, nowMs: now) == clock["accepted"] as? [String])
            }
        }
    }

    @Test("The client finds its pair in TXT h with the phone's clock up to an hour behind or ahead")
    func matchVectors() throws {
        let file = try Self.file()
        let prks = try Self.prks(file)
        let matches = file.vectors.filter { $0["kind"] as? String == "match" }
        #expect(matches.count == 5)
        for vector in matches {
            let prk = try #require(prks[try vector.string("client_pair")])
            let accepted = try DiscoveryHint.acceptedHints(prk: prk, nowMs: try vector.int("client_now_ms"))
            #expect(accepted == vector["accepted"] as? [String], "\(vector.label)")
            #expect(DiscoveryHint.matches(txtValue: try vector.string("txt_h"), accepted: accepted), "\(vector.label)")
            let position = ["previous": 0, "current": 1, "next": 2][try vector.string("matched_as")]
            #expect(position.map { accepted[$0] } == (try vector.string("matched_hint")), "\(vector.label)")
        }
    }

    @Test("Hints two hours away, with the wrong byte order, label or key never match")
    func invalidVectors() throws {
        let file = try Self.file()
        let prks = try Self.prks(file)
        #expect(file.invalidVectors.count == 6)
        for vector in file.invalidVectors {
            let prk = try #require(prks[try vector.string("pair")])
            let accepted = try DiscoveryHint.acceptedHints(prk: prk, nowMs: try vector.int("client_now_ms"))
            #expect(DiscoveryHint.hourIndex(nowMs: try vector.int("client_now_ms")) == (try vector.int("client_hour")))
            #expect(!DiscoveryHint.matches(txtValue: try vector.string("txt_h"), accepted: accepted), "\(vector.label)")
        }
    }

    @Test("TXT h matching: comma list, case-insensitive, other pairs ignored")
    func matching() {
        let accepted = ["99111c43", "c3782785", "30713410"]
        #expect(DiscoveryHint.matches(txtValue: "1a2b3c4d,99111C43", accepted: accepted))
        #expect(DiscoveryHint.matches(txtValue: "c3782785", accepted: accepted))
        #expect(!DiscoveryHint.matches(txtValue: "1a2b3c4d,77e0aa19", accepted: accepted))
        #expect(!DiscoveryHint.matches(txtValue: "", accepted: accepted))
        #expect(DiscoveryHint.hourIndex(nowMs: -1) == -1 && DiscoveryHint.hourIndex(nowMs: -3_600_000) == -1)
        #expect(DiscoveryHint.hourIndex(nowMs: -3_600_001) == -2)
    }
}
