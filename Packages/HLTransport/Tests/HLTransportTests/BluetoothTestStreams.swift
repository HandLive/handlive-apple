import Foundation
import HLProtocol
@testable import HLTransport

// MARK: - Test streams

/// Ghi lại mọi `write` để kiểm tra trên dây; `read` chờ mãi mãi cho đến khi `close`.
final class CapturingStream: BluetoothByteStream, @unchecked Sendable {
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

/// `read` trả về dữ liệu được inject từ bên ngoài; `write` bỏ qua.
final class InjectingStream: BluetoothByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var waiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var closed = false

    func inject(_ data: Data) throws {
        lock.lock()
        if closed { lock.unlock(); throw ChannelClosed(code: nil, detail: "closed") }
        if let parked = waiter, buffer.count + data.count >= parked.count {
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
        let parked = lock.withLock {
            let parked = waiter?.continuation
            waiter = nil
            closed = true
            return parked
        }
        parked?.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
    }
}

/// Cặp `BluetoothByteStream` cho test: ghi từ `local` đến `remote` và ngược lại.
/// Mỗi bên giữ một bộ đệm byte; `read(count)` trả về đúng `count` byte, hoặc chờ nếu chưa đủ.
final class BluetoothByteStreamPair: @unchecked Sendable {
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
            if let parked = remoteWaiter, remoteBuffer.count + data.count >= parked.count {
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
            if let parked = localWaiter, localBuffer.count + data.count >= parked.count {
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
        let parked: CheckedContinuation<Data, Error>?
        if fromLocal {
            localClosed = true
            parked = localWaiter?.continuation
            localWaiter = nil
        } else {
            remoteClosed = true
            parked = remoteWaiter?.continuation
            remoteWaiter = nil
        }
        lock.unlock()
        parked?.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
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
