import Foundation
import HLProtocol
import Testing
@testable import HLTransport

/// 0.4.5: ghép làn dài, một tin một lúc mỗi hướng; đóng liên kết khi tổng byte vượt `BT_MESSAGE_MAX`.
@Suite("Bluetooth long-lane reassembler (0.4.5)")
struct BluetoothLongLaneReassemblerTests {
    @Test("reassembles the two long-lane fragments of bt-frame.json")
    func reassemblesTheTwoLongLaneFragments() throws {
        let vectors = try VectorFile("bt-frame.json").vectors
        let fragment1 = try #require(vectors.first { ($0["name"] as? String)?.contains("mảnh 1/2") == true })
        let fragment2 = try #require(vectors.first { ($0["name"] as? String)?.contains("mảnh 2/2") == true })
        let reassembler = BluetoothLongLaneReassembler()
        #expect(try reassembler.accept(try BtTransportFrame.decode(fragment1.hex("plaintext"))) == nil)
        let message = try reassembler.accept(try BtTransportFrame.decode(fragment2.hex("plaintext")))
        let expected = try fragment1.hex("data") + fragment2.hex("data")
        #expect(message == expected)
    }

    @Test("a message over BT_MESSAGE_MAX closes the link even mid-stream")
    func messageOverMaxClosesTheLinkEvenMidStream() throws {
        let vector = try #require(VectorFile("bt-frame.json").invalidVectors.first { $0["reason"] as? String == "message_over_max" })
        let reassembler = BluetoothLongLaneReassembler()
        let priorFrame = BtTransportFrame(chan: 0x01, more: true, long: true,
                                          data: Data(count: Int(try vector.int("prior_bytes_received"))))
        #expect(try reassembler.accept(priorFrame) == nil)
        let lastFrame = BtTransportFrame(chan: 0x01, more: false, long: true,
                                         data: Data(count: Int(try vector.int("last_fragment_dlen"))))
        #expect(throws: BtLinkError.self) { try reassembler.accept(lastFrame) }
    }
}
