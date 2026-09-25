import Foundation
import Testing
@testable import HLCrypto

/// Expected values computed independently with Python `hmac`/`hashlib` from the `prk` of pair-prk.json
/// (no shared vector file covers the discovery hint yet).
@Suite("mDNS discovery hint (0.4.1)")
struct DiscoveryHintTests {
    struct Case {
        let pair: String
        let prk: String
        let kDisc: String
        let hints: [(Int64, String)]
    }

    static let cases: [Case] = [
        Case(pair: "cặp 1", prk: "d9e9827d49f7db11a88ac107ed6fb22b761c723c35449fc798694867fe55c209",
             kDisc: "8260d3f85773e4ce1c6047fa51bdc92bede9784df5e6311bb3068a5291ed448e",
             hints: [(479_763, "c3782785"), (479_762, "99111c43"), (0, "9b813dd8"), (1, "1786f385")]),
        Case(pair: "cặp 2", prk: "8d3109350469af80c3db25ff2c1867ab56112623020d829301236ed7251411cc",
             kDisc: "1e2fb5e7a71ef9e8afc8a44365204f6aea3a14b5fdbbdff6b225661b0051ce6a",
             hints: [(479_763, "16075d63"), (479_762, "cc68a4a9"), (0, "56e8a69c"), (1, "9260b37d")]),
    ]

    @Test("K_disc and hourly hints match an independent implementation")
    func knownValues() throws {
        let vectors = try VectorFile("pair-prk.json").vectors
        for testCase in Self.cases {
            let vector = try #require(vectors.first { ($0["name"] as? String) == testCase.pair })
            let prk = try vector.hex("prk")
            #expect(Hex.encode(prk) == testCase.prk)
            let key = try DiscoveryHint.key(prk: prk)
            #expect(Hex.encode(key) == testCase.kDisc)
            for (hour, hint) in testCase.hints {
                #expect(DiscoveryHint.hint(discoveryKey: key, hour: hour) == hint, "\(testCase.pair) hour \(hour)")
            }
        }
    }

    @Test("Accepted hints: current hour, then the previous one; hour boundaries")
    func acceptedHints() throws {
        let prk = try Hex.decode(Self.cases[0].prk)
        #expect(try DiscoveryHint.acceptedHints(prk: prk, nowMs: 1_727_150_000_123) == ["c3782785", "99111c43"])
        #expect(try DiscoveryHint.acceptedHints(prk: prk, nowMs: 3_599_999).first == "9b813dd8")
        #expect(try DiscoveryHint.acceptedHints(prk: prk, nowMs: 3_600_000) == ["1786f385", "9b813dd8"])
    }

    @Test("TXT h matching: comma list, case-insensitive, other pairs ignored")
    func matching() {
        let accepted = ["c3782785", "99111c43"]
        #expect(DiscoveryHint.matches(txtValue: "1a2b3c4d,99111C43", accepted: accepted))
        #expect(DiscoveryHint.matches(txtValue: "c3782785", accepted: accepted))
        #expect(!DiscoveryHint.matches(txtValue: "1a2b3c4d,77e0aa19", accepted: accepted))
        #expect(!DiscoveryHint.matches(txtValue: "", accepted: accepted))
    }
}
