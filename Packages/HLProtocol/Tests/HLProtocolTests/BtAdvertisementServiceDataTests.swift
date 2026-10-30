import Foundation
import Testing
@testable import HLProtocol

/// shared/test-vectors/bt-advertisement.json: scan-response service data `ver` ‖ `psm` (LE) ‖ `hints` (0.4.5
/// "Advertisement").
@Suite("Bluetooth advertisement service data (0.4.5, bt-advertisement.json)")
struct BtAdvertisementServiceDataTests {
    @Test("encode/decode match every scan_response and pin_window vector")
    func encodeAndDecodeMatchVectors() throws {
        let vectors = try VectorFile("bt-advertisement.json").vectors
        #expect(vectors.count == 4)
        for vector in vectors {
            let bytes = try vector.hex("service_data_bytes")
            let hints = try (vector["hints"] as? [String] ?? []).map { try Hex.decode($0) }
            let parsed = BtAdvertisementServiceData(psm: UInt16(try vector.int("psm")), hints: hints)
            #expect(parsed.encode() == bytes, "\(vector.label)")
            let decoded = try #require(BtAdvertisementServiceData.decode(bytes), "\(vector.label)")
            #expect(decoded == parsed, "\(vector.label)")
        }
    }

    @Test("a wrong version is ignored, not thrown")
    func wrongVersionIsIgnored() throws {
        let vector = try #require(VectorFile("bt-advertisement.json").invalidVectors.first {
            $0["reason"] as? String == "wrong_version"
        })
        #expect(BtAdvertisementServiceData.decode(try vector.hex("service_data_bytes")) == nil)
    }

    @Test("a malformed length (not ver + psm + 4×n) is ignored")
    func malformedLengthIsIgnored() {
        #expect(BtAdvertisementServiceData.decode(Data([0x01, 0x02])) == nil)
        #expect(BtAdvertisementServiceData.decode(Data([0x01, 0x02, 0x03, 0x04])) == nil)
    }
}
