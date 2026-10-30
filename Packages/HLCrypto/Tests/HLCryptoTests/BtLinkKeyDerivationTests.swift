import Foundation
import Testing
@testable import HLCrypto

/// shared/test-vectors/bt-link.json kind "key": `K_bt_disc`/`K_bt_link` = HKDF-SHA256(`PRK`, salt rỗng, info, L
/// 32) — sống suốt đời cặp (0.4.5 "Keys").
@Suite("K_bt_disc / K_bt_link derivation (0.4.5, bt-link.json)")
struct BtLinkKeyDerivationTests {
    @Test("K_bt_disc and K_bt_link match every pair's vector")
    func derivesEveryPair() throws {
        let vectors = try VectorFile("bt-link.json").vectors.filter { $0["kind"] as? String == "key" }
        #expect(vectors.count == 2)
        for vector in vectors {
            let prk = try vector.hex("prk")
            #expect(try vector.string("k_bt_disc_info") == BtLinkKeyDerivation.discoveryInfo, "\(vector.label)")
            #expect(try vector.string("k_bt_link_info") == BtLinkKeyDerivation.linkInfo, "\(vector.label)")
            #expect(BtLinkKeyDerivation.kBtDisc(prk: prk) == (try vector.hex("k_bt_disc")), "\(vector.label)")
            #expect(BtLinkKeyDerivation.kBtLink(prk: prk) == (try vector.hex("k_bt_link")), "\(vector.label)")
        }
    }
}
