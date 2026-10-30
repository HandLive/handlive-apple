import Foundation
import Testing
@testable import HLCrypto

/// shared/test-vectors/bt-link.json kind "hint": advertisement hints (0.4.5 "Advertisement"), `BT_HINT_PERIOD` =
/// 900,000 ms and the `e − 4`…`e + 4` acceptance window (CONN-05 step 3).
@Suite("Bluetooth advertisement hints (0.4.5, bt-link.json)")
struct BtAdvertisementHintTests {
    @Test("hint() matches every epoch of the vector")
    func hintMatchesVector() throws {
        let vector = try #require(VectorFile("bt-link.json").vectors.first { $0["kind"] as? String == "hint" })
        #expect(try vector.string("hint_label") == String(decoding: BtAdvertisementHint.label, as: UTF8.self))
        #expect(try vector.int("bt_hint_period_ms") == BtAdvertisementHint.periodMilliseconds)
        let keySource = try #require(VectorFile("bt-link.json").vectors.first {
            $0["kind"] as? String == "key" && ($0["name"] as? String) == (vector["k_bt_disc_source"] as? String)
        })
        let discoveryKey = try keySource.hex("k_bt_disc")
        for epoch in vector["epochs"] as? [[String: Any]] ?? [] {
            let epochIndex = try epoch.int("epoch")
            #expect(BtAdvertisementHint.hint(discoveryKey: discoveryKey, epoch: epochIndex) == (try epoch.hex("hint")),
                    "epoch \(epochIndex)")
        }
    }

    @Test("epochIndex rounds down, including for negative clocks")
    func epochIndexRoundsDown() {
        #expect(BtAdvertisementHint.epochIndex(nowMs: 0) == 0)
        #expect(BtAdvertisementHint.epochIndex(nowMs: 899_999) == 0)
        #expect(BtAdvertisementHint.epochIndex(nowMs: 900_000) == 1)
        #expect(BtAdvertisementHint.epochIndex(nowMs: -1) == -1)
        #expect(BtAdvertisementHint.epochIndex(nowMs: -900_000) == -1)
        #expect(BtAdvertisementHint.epochIndex(nowMs: -900_001) == -2)
    }

    @Test("acceptedHints covers e-4 through e+4 and matches finds the one that is there")
    func acceptedHintsCoversTheWindow() throws {
        let keyVector = try #require(VectorFile("bt-link.json").vectors.first {
            $0["kind"] as? String == "key" && ($0["name"] as? String)?.contains("cặp 1") == true
        })
        let prk = try keyVector.hex("prk")
        let nowMs: Int64 = 1_000 * BtAdvertisementHint.periodMilliseconds // epoch 1000 exactly
        let accepted = BtAdvertisementHint.acceptedHints(prk: prk, nowMs: nowMs)
        #expect(accepted.count == 9)
        let discoveryKey = BtAdvertisementHint.hint(discoveryKey: try keyVector.hex("k_bt_disc"), epoch: 996)
        #expect(accepted.first == discoveryKey)
        #expect(accepted.last == BtAdvertisementHint.hint(discoveryKey: try keyVector.hex("k_bt_disc"), epoch: 1004))
        #expect(BtAdvertisementHint.matches(advertised: [accepted[2]], accepted: accepted))
        let farAway = BtAdvertisementHint.hint(discoveryKey: try keyVector.hex("k_bt_disc"), epoch: 1005)
        #expect(!BtAdvertisementHint.matches(advertised: [farAway], accepted: accepted))
    }
}
