import Foundation
import HLProtocol
@testable import HLTransport

/// Bluetooth central whose scan results and power state the test publishes, parallel to `FakeDiscovery`.
final class FakeBluetoothCentral: BluetoothCentral, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<BluetoothCentralEvent>.Continuation?
    private var pending: [BluetoothCentralEvent] = []
    private var streams: [String: () async throws -> any BluetoothByteStream] = [:]
    private(set) var openAttempts: [(peripheralId: String, psm: UInt16)] = []

    func events() -> AsyncStream<BluetoothCentralEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            let queued = pending
            pending = []
            lock.unlock()
            queued.forEach { continuation.yield($0) }
        }
    }

    func publish(_ event: BluetoothCentralEvent) {
        lock.lock()
        let current = continuation
        if current == nil { pending.append(event) }
        lock.unlock()
        current?.yield(event)
    }

    /// Scripts what `openChannel(peripheralId:)` returns for one peripheral; replacing it mid-test is how
    /// "rotated PSM" and "next candidate" scenarios swap in a fresh stream per attempt.
    func onOpenChannel(peripheralId: String, _ makeStream: @escaping () async throws -> any BluetoothByteStream) {
        lock.lock()
        streams[peripheralId] = makeStream
        lock.unlock()
    }

    func openChannel(peripheralId: String, psm: UInt16) async throws -> any BluetoothByteStream {
        guard let maker = recordAttempt(peripheralId, psm: psm) else { throw BluetoothLinkConnectError.linkRejected }
        return try await maker()
    }

    private func recordAttempt(_ peripheralId: String, psm: UInt16) -> (() async throws -> any BluetoothByteStream)? {
        lock.lock()
        defer { lock.unlock() }
        openAttempts.append((peripheralId, psm))
        return streams[peripheralId]
    }
}

/// Two linked in-memory byte pipes — the raw-byte analogue of `InMemoryChannel.pair()`.
final class FakeBluetoothByteStream: BluetoothByteStream, @unchecked Sendable {
    private let inbox = ByteInbox()
    private weak var peer: FakeBluetoothByteStream?
    private var strongPeer: FakeBluetoothByteStream?

    static func pair() -> (client: FakeBluetoothByteStream, peripheral: FakeBluetoothByteStream) {
        let client = FakeBluetoothByteStream()
        let peripheral = FakeBluetoothByteStream()
        client.peer = peripheral
        client.strongPeer = peripheral
        peripheral.peer = client
        return (client, peripheral)
    }

    func read(_ count: Int) async throws -> Data {
        try await inbox.read(count)
    }

    func write(_ data: Data) async throws {
        guard let peer else { throw BluetoothLinkConnectError.linkRejected }
        peer.inbox.append(data)
    }

    func close() async {
        inbox.close()
        peer?.inbox.close()
    }
}

/// Byte-oriented analogue of `ChannelInbox`: buffers written bytes, serves `read(count:)` once enough have
/// accumulated. One reader at a time, like the production `ChannelInbox`/`CoreBluetoothL2CAPStream`.
private final class ByteInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var waiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var closed = false

    func append(_ data: Data) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        buffer.append(data)
        var resume: (CheckedContinuation<Data, Error>, Data)?
        if let waiter, buffer.count >= waiter.count {
            self.waiter = nil
            let result = buffer.prefix(waiter.count)
            buffer.removeFirst(waiter.count)
            resume = (waiter.continuation, Data(result))
        }
        lock.unlock()
        if let resume { resume.0.resume(returning: resume.1) }
    }

    func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.beginRead(count: count, continuation: continuation)
        }
    }

    private func beginRead(count: Int, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        let isClosed = closed
        var ready: Data?
        if !isClosed {
            precondition(waiter == nil, "one reader at a time")
            if buffer.count >= count {
                ready = buffer.prefix(count)
                buffer.removeFirst(count)
            } else {
                waiter = (count, continuation)
            }
        }
        lock.unlock()
        if isClosed {
            continuation.resume(throwing: BluetoothLinkConnectError.linkRejected)
        } else if let ready {
            continuation.resume(returning: ready)
        }
    }

    func close() {
        lock.lock()
        closed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.continuation.resume(throwing: BluetoothLinkConnectError.linkRejected)
    }
}

/// Plays S's half of the link-security handshake (0.4.5 steps 1–4) with canned `bt-link.json` bytes — scripted,
/// not computed, since Apple has no S-role Noise implementation (M-APP is always C, 0.4.5 "Roles"). Once that
/// succeeds it hands back a real `BluetoothChannel` with S's keys swapped (`sealKey`/`openKey` reversed from the
/// client's), so `FakePhone` runs on top of it unmodified, exactly as it would over any other `MessageChannel`.
final class FakeBluetoothPeripheral {
    private let stream: FakeBluetoothByteStream
    private let challengeRecord: Data
    private let noise2Record: Data
    private let sealKey: Data
    private let openKey: Data

    init(stream: FakeBluetoothByteStream, challengeRecord: Data, noise2Record: Data, sealKey: Data, openKey: Data) {
        self.stream = stream
        self.challengeRecord = challengeRecord
        self.noise2Record = noise2Record
        self.sealKey = sealKey
        self.openKey = openKey
    }

    /// Runs steps 1–4; the caller only awaits this when it expects the client to complete them (a tampered
    /// `noise2Record` makes the client give up before the stream carries anything else, so there is nothing
    /// here to read in that case).
    func runHandshake() async throws -> BluetoothChannel {
        try await stream.write(challengeRecord)
        _ = try await readRecord() // noise1 — the canned noise2 already answers for the vector's own noise1
        try await stream.write(noise2Record)
        return BluetoothChannel(stream: stream, sealKey: sealKey, openKey: openKey)
    }

    private func readRecord() async throws -> Data {
        let rlen = BtRecordCodec.decodeRlen(try await stream.read(BtRecordCodec.lengthPrefixSize))
        return try await stream.read(rlen)
    }
}
