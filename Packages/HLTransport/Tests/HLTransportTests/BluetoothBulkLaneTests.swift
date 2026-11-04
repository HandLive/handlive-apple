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

    // MARK: - Rule 4: BT_BULK_QUEUED backpressure

    @Test("send(.bulkText) blocks while BT_BULK_QUEUED envelopes are pending")
    func bulkTextBackpressure() async throws {
        let stream = BlockingStream()
        let channel = BluetoothChannel(stream: stream, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        let envelope = String(repeating: "x", count: 100)
        // Hai send đầu tiên đã xếp hàng (BT_BULK_QUEUED = 2). Send thứ ba phải chờ.
        let first = Task { try await channel.send(.bulkText(envelope)) }
        let second = Task { try await channel.send(.bulkText(envelope)) }
        try await Task.sleep(for: .milliseconds(50))
        let pending = await channel.pendingBulkEnvelopes
        #expect(pending == 2)
        // Send thứ ba chưa xong vì backpressure.
        let third = Task { try await channel.send(.bulkText(envelope)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(third.isCancelled == false)
        #expect(await channel.pendingBulkEnvelopes == 2)
        // Đóng kênh để giải phóng các send đang chờ.
        await channel.close(code: .normal)
        first.cancel()
        second.cancel()
        third.cancel()
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

// MARK: - Test streams

/// Ghi lại mọi `write` để kiểm tra trên dây; `read` chờ mãi mãi cho đến khi `close`.
private final class CapturingStream: BluetoothByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [Data] = []
    private var reader: CheckedContinuation<Data, Error>?
    private var closed = false

    func write(_ data: Data) async throws {
        lock.withLock { written.append(data) }
    }

    func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let isClosed = lock.withLock {
                if !closed { reader = continuation }
                return closed
            }
            if isClosed { continuation.resume(throwing: ChannelClosed(code: nil, detail: "closed")) }
        }
    }

    func close() async {
        let parked = lock.withLock {
            closed = true
            defer { reader = nil }
            return reader
        }
        parked?.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
    }

    func decodedFrames(sealKey: Data) throws -> [BtTransportFrame] {
        let cipher = BtTransportCipher(initialKey: sealKey)
        return try lock.withLock {
            try written.map { record in
                let rlen = BtRecordCodec.decodeRlen(record.subdata(in: 0..<BtRecordCodec.lengthPrefixSize))
                let ciphertextTag = record.subdata(in: BtRecordCodec.lengthPrefixSize..<(BtRecordCodec.lengthPrefixSize + rlen))
                let plaintext = try cipher.open(ciphertextTag)
                return try BtTransportFrame.decode(plaintext)
            }
        }
    }
}

/// `write` chờ mãi mãi cho đến khi `close` — dùng để kiểm tra backpressure.
private final class BlockingStream: BluetoothByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var writer: CheckedContinuation<Void, Error>?
    private var reader: CheckedContinuation<Data, Error>?
    private var closed = false

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let isClosed = lock.withLock {
                if !closed { writer = continuation }
                return closed
            }
            if isClosed { continuation.resume(throwing: ChannelClosed(code: nil, detail: "closed")) }
        }
    }

    func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let isClosed = lock.withLock {
                if !closed { reader = continuation }
                return closed
            }
            if isClosed { continuation.resume(throwing: ChannelClosed(code: nil, detail: "closed")) }
        }
    }

    func close() async {
        let (parkedWriter, parkedReader) = lock.withLock {
            let w = writer
            let r = reader
            writer = nil
            reader = nil
            closed = true
            return (w, r)
        }
        parkedWriter?.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
        parkedReader?.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
    }
}

/// `read` trả về dữ liệu được inject từ bên ngoài; `write` bỏ qua.
private final class InjectingStream: BluetoothByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var waiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var closed = false

    func inject(_ data: Data) throws {
        lock.lock()
        if closed { lock.unlock(); throw ChannelClosed(code: nil, detail: "closed") }
        if let w = waiter, buffer.count + data.count >= w.count {
            buffer.append(data)
            let waiter = waiter!
            self.waiter = nil
            let result = buffer.prefix(waiter.count)
            buffer.removeFirst(waiter.count)
            lock.unlock()
            waiter.continuation.resume(returning: Data(result))
        } else {
            buffer.append(data)
            lock.unlock()
        }
    }

    func write(_ data: Data) async throws {}

    func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if buffer.count >= count {
                let result = buffer.prefix(count)
                buffer.removeFirst(count)
                lock.unlock()
                continuation.resume(returning: Data(result))
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
            } else {
                waiter = (count, continuation)
                lock.unlock()
            }
        }
    }

    func close() async {
        let w = lock.withLock {
            let w = waiter?.continuation
            waiter = nil
            closed = true
            return w
        }
        w?.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
    }
}

/// Cặp `BluetoothByteStream` cho test: ghi từ `local` đến `remote` và ngược lại.
/// Mỗi bên giữ một bộ đệm byte; `read(count)` trả về đúng `count` byte, hoặc chờ nếu chưa đủ.
private final class BluetoothByteStreamPair: @unchecked Sendable {
    var local: BluetoothByteStream!
    var remote: BluetoothByteStream!
    private let lock = NSLock()
    private var localBuffer = Data()
    private var remoteBuffer = Data()
    private var localWaiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var remoteWaiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var localClosed = false
    private var remoteClosed = false

    init() {
        local = LocalEnd(self, isLocal: true)
        remote = LocalEnd(self, isLocal: false)
    }

    func write(fromLocal: Bool, data: Data) throws {
        lock.lock()
        if fromLocal {
            if let w = remoteWaiter, remoteBuffer.count + data.count >= w.count {
                remoteBuffer.append(data)
                let waiter = remoteWaiter!
                remoteWaiter = nil
                let result = remoteBuffer.prefix(waiter.count)
                remoteBuffer.removeFirst(waiter.count)
                lock.unlock()
                waiter.continuation.resume(returning: Data(result))
            } else {
                remoteBuffer.append(data)
                lock.unlock()
            }
        } else {
            if let w = localWaiter, localBuffer.count + data.count >= w.count {
                localBuffer.append(data)
                let waiter = localWaiter!
                localWaiter = nil
                let result = localBuffer.prefix(waiter.count)
                localBuffer.removeFirst(waiter.count)
                lock.unlock()
                waiter.continuation.resume(returning: Data(result))
            } else {
                localBuffer.append(data)
                lock.unlock()
            }
        }
    }

    func read(fromLocal: Bool, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if fromLocal {
                if localBuffer.count >= count {
                    let result = localBuffer.prefix(count)
                    localBuffer.removeFirst(count)
                    lock.unlock()
                    continuation.resume(returning: Data(result))
                } else if localClosed {
                    lock.unlock()
                    continuation.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
                } else {
                    localWaiter = (count, continuation)
                    lock.unlock()
                }
            } else {
                if remoteBuffer.count >= count {
                    let result = remoteBuffer.prefix(count)
                    remoteBuffer.removeFirst(count)
                    lock.unlock()
                    continuation.resume(returning: Data(result))
                } else if remoteClosed {
                    lock.unlock()
                    continuation.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
                } else {
                    remoteWaiter = (count, continuation)
                    lock.unlock()
                }
            }
        }
    }

    func close(fromLocal: Bool) {
        lock.lock()
        let w: CheckedContinuation<Data, Error>?
        if fromLocal {
            localClosed = true
            w = localWaiter?.continuation
            localWaiter = nil
        } else {
            remoteClosed = true
            w = remoteWaiter?.continuation
            remoteWaiter = nil
        }
        lock.unlock()
        w?.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
    }

    private final class LocalEnd: BluetoothByteStream, @unchecked Sendable {
        let pair: BluetoothByteStreamPair
        let isLocal: Bool

        init(_ pair: BluetoothByteStreamPair, isLocal: Bool) {
            self.pair = pair
            self.isLocal = isLocal
        }

        func write(_ data: Data) async throws {
            try pair.write(fromLocal: isLocal, data: data)
        }

        func read(_ count: Int) async throws -> Data {
            try await pair.read(fromLocal: isLocal, count: count)
        }

        func close() async {
            pair.close(fromLocal: isLocal)
        }
    }
}
