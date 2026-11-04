import Foundation
import HLProtocol
import Testing
@testable import HLTransport

/// 0.4.7 "Bulk lane on the Bluetooth link": bulk envelopes (CLIP-03 transfer) đi kênh `0x02` với backpressure
/// `BT_BULK_QUEUED`; control envelopes đi kênh `0x01`; reassembled bulk đi lên dưới dạng `.text`; vi phạm cận
/// đóng liên kết.
@Suite("Bluetooth bulk lane (0.4.7)")
struct BluetoothBulkLaneTests {
    // MARK: - Rule 1: bulkText goes on channel 0x02, text goes on 0x01

    @Test("bulkText travels on channel 0x02, text on 0x01")
    func bulkTextOnChannel0x02TextOn0x01() async throws {
        let stream = CapturingStream()
        let channel = BluetoothChannel(stream: stream, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        let bulkEnvelope = #"{"v":1,"type":"clipboard","id":"a","ts":1,"payload":"BULK"}"#
        let controlEnvelope = #"{"v":1,"type":"ping","id":"b","ts":2,"payload":"CTRL"}"#
        try await channel.send(.bulkText(bulkEnvelope))
        try await channel.send(.text(controlEnvelope))

        // Giải mã các khung đã ghi và kiểm tra kênh.
        let frames = try stream.decodedFrames(sealKey: Data(repeating: 1, count: 32))
        let bulkFrame = try #require(frames.first { $0.chan == BtLinkConstants.chanBulk })
        let controlFrame = try #require(frames.first { $0.chan == BtLinkConstants.chanControl })
        #expect(bulkFrame.data == Data(bulkEnvelope.utf8))
        #expect(controlFrame.data == Data(controlEnvelope.utf8))

        await channel.close(code: .normal)
    }

    // MARK: - Rule 5: link closes on long=1 on 0x02, on dlen > bulkFragmentMax, on message > messageMax

    @Test("a 0x02 fragment with long=1 closes the link")
    func longFlagOnBulkClosesLink() async throws {
        let stream = InjectingStream()
        let channel = BluetoothChannel(stream: stream, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        // Gửi một khung `0x02` với `long` = 1 từ phía peer.
        let badFrame = BtTransportFrame.encode(chan: BtLinkConstants.chanBulk, more: false, long: true, data: Data([0]))
        let sealed = try BtTransportCipher(initialKey: Data(repeating: 2, count: 32)).seal(badFrame)
        try stream.inject(BtRecordCodec.encode(sealed))
        // Channel phải đóng.
        await #expect(throws: ChannelClosed.self) { try await channel.receive() }
        await channel.close(code: .normal)
    }

    @Test("a 0x02 fragment with dlen over BT_BULK_FRAGMENT_MAX closes the link")
    func dlenOverBulkFragmentMaxClosesLink() async throws {
        let stream = InjectingStream()
        let channel = BluetoothChannel(stream: stream, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        // Dựng plaintext thủ công với `dlen` = 1021 (vượt `bulkFragmentMax` = 1020).
        // `BtTransportFrame.encode` có precondition nên không dùng được ở đây.
        let dlen = BtLinkConstants.bulkFragmentMax + 1
        let paddedSize = BtLinkConstants.paddedPlaintextSizes.last! // 4096
        var plaintext = Data(count: paddedSize)
        plaintext[0] = UInt8(BtLinkConstants.chanBulk)
        plaintext[1] = 0 // more=0, long=0
        plaintext[2] = UInt8((dlen >> 8) & 0xFF)
        plaintext[3] = UInt8(dlen & 0xFF)
        let sealed = try BtTransportCipher(initialKey: Data(repeating: 2, count: 32)).seal(plaintext)
        try stream.inject(BtRecordCodec.encode(sealed))
        await #expect(throws: ChannelClosed.self) { try await channel.receive() }
        await channel.close(code: .normal)
    }

    @Test("a bulk message over BT_MESSAGE_MAX closes the link")
    func bulkMessageOverMaxClosesLink() async throws {
        let stream = InjectingStream()
        let channel = BluetoothChannel(stream: stream, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        // Gửi đủ mảnh `bulkFragmentMax` để tổng vượt `messageMax` (256 KiB).
        // Cần ít nhất 258 mảnh × 1020 byte = 263160 > 262144.
        let fragmentSize = BtLinkConstants.bulkFragmentMax
        let totalFragments = (BtLinkConstants.messageMax / fragmentSize) + 2
        for index in 0..<totalFragments {
            let isLast = index == totalFragments - 1
            let frame = BtTransportFrame.encode(chan: BtLinkConstants.chanBulk, more: !isLast, long: false,
                                                data: Data(count: fragmentSize))
            let sealed = try BtTransportCipher(initialKey: Data(repeating: 2, count: 32)).seal(frame)
            try stream.inject(BtRecordCodec.encode(sealed))
        }
        await #expect(throws: ChannelClosed.self) { try await channel.receive() }
        await channel.close(code: .normal)
    }

    // MARK: - Rule 6: reassembled bulk message delivered as .text

    @Test("a multi-fragment bulk message reassembles into one .text")
    func multiFragmentBulkReassembles() async throws {
        let pair = BluetoothByteStreamPair()
        let channel = BluetoothChannel(stream: pair.local, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        let peer = BluetoothChannel(stream: pair.remote, sealKey: Data(repeating: 2, count: 32),
                                    openKey: Data(repeating: 1, count: 32))
        // Phong bì bulk lớn hơn `bulkFragmentMax` → nhiều mảnh.
        let envelope = String(repeating: "A", count: BtLinkConstants.bulkFragmentMax + 100)
        try await channel.send(.bulkText(envelope))
        let received = try await peer.receive()
        #expect(received == .text(envelope))
        await channel.close(code: .normal)
        await peer.close(code: .normal)
    }

    // MARK: - Rule 8: half-reassembled bulk message dropped at link close

    @Test("a half-reassembled bulk message is dropped when the link closes")
    func halfReassembledBulkDropped() async throws {
        let pair = BluetoothByteStreamPair()
        let channel = BluetoothChannel(stream: pair.local, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        let peer = BluetoothChannel(stream: pair.remote, sealKey: Data(repeating: 2, count: 32),
                                    openKey: Data(repeating: 1, count: 32))
        // Gửi mảnh đầu của một tin bulk từ phía peer, KHÔNG gửi mảnh cuối.
        let first = BtTransportFrame.encode(chan: BtLinkConstants.chanBulk, more: true, long: false,
                                            data: Data(repeating: 0x41, count: 100))
        let sealed = try BtTransportCipher(initialKey: Data(repeating: 2, count: 32)).seal(first)
        try await pair.local.write(BtRecordCodec.encode(sealed))
        // Đóng liên kết.
        await channel.close(code: .normal)
        // Peer phải đóng mà không giao tin nào.
        await #expect(throws: ChannelClosed.self) { try await peer.receive() }
    }
}
