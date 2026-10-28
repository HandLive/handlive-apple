import Foundation
import Testing
@testable import HLProtocol

/// shared/test-vectors/bt-frame.json kind "transport_frame": `chan` ‖ `flags` (`more`/`long`) ‖ `dlen` ‖ `data`
/// ‖ đệm (0.4.5).
@Suite("Bluetooth transport frames (0.4.5, bt-frame.json)")
struct BtTransportFrameTests {
    static func vectors() throws -> [[String: Any]] {
        try VectorFile("bt-frame.json").vectors.filter { $0["kind"] as? String == "transport_frame" }
    }

    @Test("encode matches the vector plaintext")
    func encodeMatchesVectorPlaintext() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 4)
        for vector in vectors {
            let chan = try Int(parsingHex: vector.string("chan"))
            let plaintext = BtTransportFrame.encode(chan: chan, more: try vector.bool("more"),
                                                     long: try vector.bool("long"), data: try vector.hex("data"))
            #expect(plaintext == (try vector.hex("plaintext")), "\(vector.label)")
            #expect(plaintext.count == Int(try vector.int("padded_size")), "\(vector.label)")
        }
    }

    @Test("decode matches the vector fields")
    func decodeMatchesVectorFields() throws {
        for vector in try Self.vectors() {
            let frame = try BtTransportFrame.decode(vector.hex("plaintext"))
            #expect(frame.chan == (try Int(parsingHex: vector.string("chan"))), "\(vector.label)")
            #expect(frame.more == (try vector.bool("more")), "\(vector.label)")
            #expect(frame.long == (try vector.bool("long")), "\(vector.label)")
            #expect(frame.data == (try vector.hex("data")), "\(vector.label)")
        }
    }

    @Test("an unknown chan closes the link")
    func unknownChanClosesTheLink() throws {
        let vector = try #require(VectorFile("bt-frame.json").invalidVectors.first { $0["reason"] as? String == "unknown_chan" })
        let plaintext = try vector.hex("plaintext")
        #expect(throws: BtLinkError.self) { try BtTransportFrame.decode(plaintext) }
    }

    @Test("more without long closes the link")
    func moreWithoutLongClosesTheLink() throws {
        let vector = try #require(VectorFile("bt-frame.json").invalidVectors.first { $0["reason"] as? String == "more_without_long" })
        let plaintext = try vector.hex("plaintext")
        #expect(throws: BtLinkError.self) { try BtTransportFrame.decode(plaintext) }
    }

    @Test("a bulk/long fragment over the max closes the link")
    func bulkFragmentOverMaxClosesTheLink() throws {
        let vector = try #require(VectorFile("bt-frame.json").invalidVectors.first { $0["reason"] as? String == "bulk_fragment_over_max" })
        let dlen = Int(try vector.int("dlen"))
        #expect(Int(try vector.int("bt_bulk_fragment_max")) == BtLinkConstants.bulkFragmentMax)
        #expect(dlen > BtLinkConstants.bulkFragmentMax)
        // Vector chỉ tả cận, không cho byte cụ thể — dựng thủ công một plaintext có dlen vượt cận để kiểm decode.
        var padded = Data(count: 4096)
        padded[0] = UInt8(try Int(parsingHex: vector.string("chan")))
        padded[1] = 0x02 // long = 1
        padded[2] = UInt8((dlen >> 8) & 0xFF)
        padded[3] = UInt8(dlen & 0xFF)
        #expect(throws: BtLinkError.self) { try BtTransportFrame.decode(padded) }
    }

    @Test("maxDlen matches each lane")
    func maxDlenMatchesEachLane() {
        let control = BtLinkConstants.chanControl
        let bulk = BtLinkConstants.chanBulk
        #expect(BtTransportFrame.maxDlen(chan: control, long: false) == BtLinkConstants.fragmentMax)
        #expect(BtTransportFrame.maxDlen(chan: control, long: true) == BtLinkConstants.bulkFragmentMax)
        #expect(BtTransportFrame.maxDlen(chan: bulk, long: false) == BtLinkConstants.bulkFragmentMax)
    }

    @Test("paddedSize fits the smallest tier")
    func paddedSizeFitsTheSmallestTier() {
        #expect(BtTransportFrame.paddedSize(for: 4) == 256)
        #expect(BtTransportFrame.paddedSize(for: 1024) == 1024)
        #expect(BtTransportFrame.paddedSize(for: 1025) == 4096)
        #expect(!(BtTransportFrame.paddedSize(for: 256) > 256))
    }
}
