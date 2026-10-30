import Foundation
import HLProtocol
import Testing
@testable import HLTransport

/// `BluetoothChannel.send` called from several tasks at once (SMS sync and call-log sync over one link): the
/// real `CoreBluetoothL2CAPStream` traps on a second concurrent `write`, so the channel must never overlap
/// writes even though its writer actor is reentrant across `await stream.write`.
@Suite("Bluetooth channel concurrent sends")
struct BluetoothChannelConcurrentSendTests {
    @Test("concurrent sends never overlap stream writes and all reach the stream")
    func concurrentSendsNeverOverlapWrites() async throws {
        let stream = SlowWriteStream()
        let channel = BluetoothChannel(stream: stream, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        let senders = 8
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<senders {
                group.addTask { try await channel.send(.binary(Data(repeating: UInt8(index), count: 16))) }
            }
            try await group.waitForAll()
        }
        #expect(stream.maxConcurrentWriters == 1)
        #expect(stream.writeCount == senders)
        await channel.close(code: .normal)
    }

    @Test("a failed write fails every send waiting on the same drain")
    func failedWriteFailsWaitingSends() async throws {
        let stream = SlowWriteStream(failWrites: true)
        let channel = BluetoothChannel(stream: stream, sealKey: Data(repeating: 1, count: 32),
                                       openKey: Data(repeating: 2, count: 32))
        let failures = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<4 {
                group.addTask {
                    do {
                        try await channel.send(.binary(Data([UInt8(index)])))
                        return false
                    } catch {
                        return true
                    }
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(failures == 4)
        #expect(stream.maxConcurrentWriters == 1)
        await channel.close(code: .normal)
    }
}

/// A byte stream whose `write` suspends long enough for other senders to arrive, recording how many writes
/// were in flight at once; `read` parks until `close` so the channel's read loop stays idle.
private final class SlowWriteStream: BluetoothByteStream, @unchecked Sendable {
    private struct WriteFailed: Error {}

    private let lock = NSLock()
    private let failWrites: Bool
    private var activeWriters = 0
    private var reader: CheckedContinuation<Data, Error>?
    private var closed = false
    private(set) var maxConcurrentWriters = 0
    private(set) var writeCount = 0

    init(failWrites: Bool = false) {
        self.failWrites = failWrites
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            activeWriters += 1
            maxConcurrentWriters = max(maxConcurrentWriters, activeWriters)
        }
        try? await Task.sleep(for: .milliseconds(5))
        lock.withLock {
            activeWriters -= 1
            writeCount += 1
        }
        if failWrites { throw WriteFailed() }
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
}
