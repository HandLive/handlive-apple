import Foundation
import Testing
@testable import HLProtocol

/// shared/test-vectors/bt-frame.json: `rlen` (uint16 BE) ‖ thân — cận kiểm trước khi cấp phát (0.4.5 "Link
/// records", review #165).
@Suite("Bluetooth link records: rlen framing (0.4.5, bt-frame.json)")
struct BtRecordCodecTests {
    @Test("encode/decodeRlen round-trips every preauth_frame vector")
    func encodeAndDecodeRlenRoundTrip() throws {
        let vectors = try VectorFile("bt-frame.json").vectors.filter { $0["kind"] as? String == "preauth_frame" }
        for vector in vectors {
            let record = try vector.hex("record")
            let body = try vector.hex("body")
            #expect(BtRecordCodec.encode(body) == record, "\(vector.label)")
            #expect(BtRecordCodec.decodeRlen(record.prefix(2)) == body.count, "\(vector.label)")
        }
    }

    @Test("an rlen outside the three transport sizes closes before allocating")
    func rlenOutOfBoundsClosesBeforeAllocating() throws {
        let vector = try #require(VectorFile("bt-frame.json").invalidVectors.first { $0["reason"] as? String == "rlen_out_of_bounds" })
        let record = try vector.hex("record")
        let rlen = BtRecordCodec.decodeRlen(record.prefix(2))
        #expect(rlen == Int(try vector.int("rlen")))
        #expect(throws: BtLinkError.self) { try BtRecordCodec.requireValidTransportRlen(rlen) }
    }

    @Test("a pre-auth record over the bound closes before allocating")
    func preauthRecordOverBoundClosesBeforeAllocating() throws {
        let vector = try #require(VectorFile("bt-frame.json").invalidVectors
            .first { $0["reason"] as? String == "preauth_record_over_bound" })
        let record = try vector.hex("record")
        let rlen = BtRecordCodec.decodeRlen(record.prefix(2))
        #expect(rlen == Int(try vector.int("rlen")))
        #expect(Int(try vector.int("bt_preauth_record_max")) == BtLinkConstants.preauthRecordMax)
        #expect(throws: BtLinkError.self) { try BtRecordCodec.requireWithinBound(rlen, maxBodySize: BtLinkConstants.preauthRecordMax) }
    }

    @Test("every valid transport rlen never throws")
    func validTransportRlensNeverThrow() throws {
        for rlen in BtLinkConstants.transportRecordSizes {
            try BtRecordCodec.requireValidTransportRlen(rlen)
        }
    }
}
