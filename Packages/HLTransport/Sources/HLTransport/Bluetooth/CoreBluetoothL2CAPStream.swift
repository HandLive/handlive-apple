import CoreBluetooth
import Foundation

/// `BluetoothByteStream` over a `CBL2CAPChannel`'s input/output streams (Foundation `Stream`, not a raw socket):
/// mirrors `Tools/BLESpike/Sources/BLESpike/FramedChannel.swift`'s stream-delegate plumbing, as an async
/// read/write seam instead of a frame-level callback API. One reader and one writer at a time, like
/// `ChannelInbox` — `BluetoothLinkConnector` and `BluetoothChannel` never read or write concurrently with
/// themselves. **Not measured on a real device yet** (M7.1c Gói B); `NSBluetoothAlwaysUsageDescription` is
/// M7.7a's, so this cannot even start on a Mac until that lands.
final class CoreBluetoothL2CAPStream: NSObject, BluetoothByteStream, StreamDelegate, @unchecked Sendable {
    private let channel: CBL2CAPChannel
    private let lock = NSLock()
    private var readBuffer = Data()
    private var readWaiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var pendingWrite = Data()
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var closedError: Error?

    init(channel: CBL2CAPChannel) {
        self.channel = channel
        super.init()
        channel.inputStream.delegate = self
        channel.outputStream.delegate = self
        // Streams only accept reads/writes on the thread that scheduled their run loop (BLESpike's
        // `FramedChannel`, same constraint): main, so every `Stream.Event` callback lands there too.
        channel.inputStream.schedule(in: .main, forMode: .default)
        channel.outputStream.schedule(in: .main, forMode: .default)
        channel.inputStream.open()
        channel.outputStream.open()
    }

    func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.beginRead(count: count, continuation: continuation)
        }
    }

    private func beginRead(count: Int, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        let closedError = self.closedError
        var ready: Data?
        if closedError == nil {
            precondition(readWaiter == nil, "one reader at a time")
            if readBuffer.count >= count {
                ready = readBuffer.prefix(count)
                readBuffer.removeFirst(count)
            } else {
                readWaiter = (count, continuation)
            }
        }
        lock.unlock()
        if let closedError {
            continuation.resume(throwing: closedError)
        } else if let ready {
            continuation.resume(returning: ready)
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.beginWrite(data, continuation: continuation)
        }
    }

    private func beginWrite(_ data: Data, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let closedError = self.closedError
        if closedError == nil {
            precondition(writeWaiter == nil, "one writer at a time")
            pendingWrite.append(data)
            writeWaiter = continuation
        }
        lock.unlock()
        if let closedError {
            continuation.resume(throwing: closedError)
        } else {
            DispatchQueue.main.async { [weak self] in self?.flushIfPossible() }
        }
    }

    func close() async {
        channel.inputStream.close()
        channel.outputStream.close()
    }

    private func flushIfPossible() {
        lock.lock()
        guard !pendingWrite.isEmpty, channel.outputStream.hasSpaceAvailable else {
            lock.unlock()
            return
        }
        let written = pendingWrite.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return channel.outputStream.write(base, maxLength: pendingWrite.count)
        }
        if written > 0 { pendingWrite.removeFirst(written) }
        var done: CheckedContinuation<Void, Error>?
        if pendingWrite.isEmpty {
            done = writeWaiter
            writeWaiter = nil
        }
        lock.unlock()
        done?.resume()
    }

    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let read = (stream as? InputStream)?.read(&chunk, maxLength: chunk.count) ?? 0
            guard read > 0 else { return }
            deliver(Data(chunk[0..<read]))
        case .hasSpaceAvailable:
            flushIfPossible()
        case .endEncountered, .errorOccurred:
            fail(ChannelClosed(code: nil, detail: "l2cap stream \(eventCode)"))
        default:
            break
        }
    }

    private func deliver(_ chunk: Data) {
        lock.lock()
        readBuffer.append(chunk)
        var done: (CheckedContinuation<Data, Error>, Data)?
        if let waiter = readWaiter, readBuffer.count >= waiter.count {
            readWaiter = nil
            let result = readBuffer.prefix(waiter.count)
            readBuffer.removeFirst(waiter.count)
            done = (waiter.continuation, Data(result))
        }
        lock.unlock()
        if let done { done.0.resume(returning: done.1) }
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard closedError == nil else {
            lock.unlock()
            return
        }
        closedError = error
        let failedRead = readWaiter
        readWaiter = nil
        let failedWrite = writeWaiter
        writeWaiter = nil
        lock.unlock()
        failedRead?.continuation.resume(throwing: error)
        failedWrite?.resume(throwing: error)
    }
}
