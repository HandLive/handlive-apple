import Foundation
import HLProtocol
import Testing
@testable import HLTransport

/// 0.4.7 "Bulk lane on the Bluetooth link" ở mức kênh: control chen trước bulk (luật 7, 0.4.5 "Priority"), ảnh 10 MiB
/// qua ống trong bộ nhớ, và đường LAN/relay không đổi (luật mở đầu: ngoài Bluetooth chỉ có một lane).
@Suite("Bluetooth bulk lane: priority, 10 MiB image, other routes (0.4.7)")
struct BluetoothBulkLaneTransferTests {
    private static let sealKey = Data(repeating: 1, count: 32)
    private static let openKey = Data(repeating: 2, count: 32)

    @Test("0.4.7 bulk rule 7: a control envelope sent while a bulk one is being written goes between its fragments")
    func controlOvertakesBulk() async throws {
        let stream = GateStream()
        let channel = BluetoothChannel(stream: stream, sealKey: Self.sealKey, openKey: Self.openKey)
        let bulk = String(repeating: "B", count: BtLinkConstants.bulkFragmentMax * 6)
        let control = #"{"v":1,"type":"ping","id":"p","ts":1,"payload":"CTRL"}"#
        let bulkSend = Task { try await channel.send(.bulkText(bulk)) }
        #expect(await stream.waitForWrites(1)) // mảnh bulk đầu đang ghi dở
        let controlSend = Task { try await channel.send(.text(control)) }
        try await Task.sleep(for: .milliseconds(50))
        stream.release()
        try await bulkSend.value
        try await controlSend.value

        let frames = try stream.decodedFrames(sealKey: Self.sealKey)
        let channels = frames.map(\.chan)
        #expect(channels.count == 7)
        #expect(channels.first == BtLinkConstants.chanBulk)
        #expect(channels[1] == BtLinkConstants.chanControl, "control đi ngay sau mảnh đang ghi")
        #expect(channels.dropFirst(2).allSatisfy { $0 == BtLinkConstants.chanBulk })
        await channel.close(code: .normal)
    }

    @Test("0.4.7 bulk rule 4: with BT_BULK_QUEUED envelopes waiting, the next send(.bulkText) does not return")
    func bulkSendWaitsWhenQueueIsFull() async throws {
        let stream = GateStream()
        let channel = BluetoothChannel(stream: stream, sealKey: Self.sealKey, openKey: Self.openKey)
        let envelope = String(repeating: "x", count: BtLinkConstants.bulkFragmentMax * 2)
        let done = Flags()
        let sends = (0..<3).map { index in
            Task {
                try await channel.send(.bulkText(envelope))
                done.set(index)
            }
        }
        #expect(await stream.waitForWrites(1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await channel.pendingBulkEnvelopes == BluetoothLinkConstants.bulkQueued)
        #expect(done.isEmpty, "chưa phong bì nào ghi xong, lần gửi thứ ba còn chờ chỗ")
        stream.release()
        for send in sends { try await send.value }
        #expect(done.count == 3)
        #expect(await channel.pendingBulkEnvelopes == 0)
        await channel.close(code: .normal)
    }

    @Test("CLIP-03 over Bluetooth: a 10 MiB image in 64 KiB chunks arrives whole and in order, control envelopes too")
    func tenMiBImageCompletes() async throws {
        let pair = BluetoothByteStreamPair()
        let sender = BluetoothChannel(stream: pair.local, sealKey: Self.sealKey, openKey: Self.openKey)
        let receiver = BluetoothChannel(stream: pair.remote, sealKey: Self.openKey, openKey: Self.sealKey)
        let chunkSize = 65_536
        let image = Data((0..<(10 * 1_048_576)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let chunkCount = image.count / chunkSize
        let pingEvery = 40
        let chunkIDs = (0..<chunkCount).map { _ in HLUUID.v7() }
        let expectedPings = (0..<chunkCount).filter { $0 % pingEvery == 0 }.map { _ in HLUUID.v7() }

        let sending = Task {
            for index in 0..<chunkCount {
                let part = image.subdata(in: (index * chunkSize)..<((index + 1) * chunkSize))
                let payload = Base64Coding.encodeB64(part)
                let envelope = #"{"v":1,"type":"clipboard","id":"\#(chunkIDs[index])","ts":1,"payload":"\#(payload)"}"#
                try await sender.send(.bulkText(envelope))
                if index % pingEvery == 0 {
                    let ping = expectedPings[index / pingEvery]
                    try await sender.send(.text(#"{"v":1,"type":"ping","id":"\#(ping)","ts":1,"payload":"AAAA"}"#))
                }
            }
        }

        var assembled = Data()
        var chunksSeen = 0
        var pingsSeen: [String] = []
        while chunksSeen < chunkCount || pingsSeen.count < expectedPings.count {
            guard case .text(let text) = try await receiver.receive() else {
                Issue.record("only text arrives on the Bluetooth link")
                break
            }
            let envelope = try Envelope.parse(Data(text.utf8))
            if envelope.type == .ping {
                pingsSeen.append(envelope.id)
            } else {
                #expect(envelope.id == chunkIDs[chunksSeen], "chunk theo đúng thứ tự gửi (CLIP-03 API 4 luật 2)")
                assembled.append(try envelope.payloadBytes)
                chunksSeen += 1
            }
        }
        try await sending.value
        #expect(assembled == image)
        #expect(pingsSeen == expectedPings)
        await sender.close(code: .normal)
        await receiver.close(code: .normal)
    }

    @Test("0.4.7 bulk rule 6: .binary never travels on the Bluetooth link; send(.binary) throws and nothing is written")
    func binaryIsRejected() async throws {
        let stream = GateStream()
        stream.release()
        let channel = BluetoothChannel(stream: stream, sealKey: Self.sealKey, openKey: Self.openKey)
        await #expect(throws: ChannelClosed.self) { try await channel.send(.binary(Data([0x48, 0x4C, 1]))) }
        #expect(stream.writeCount == 0)
        await channel.close(code: .normal)
    }

    @Test("Regression CLIP-03 on the LAN: .bulkText crosses a real WebSocket as one text frame on /v1/ctl")
    func lanSendsBulkTextAsTextFrame() async throws {
        guard let server = try TLSTestServer.start() else { return }
        defer { server.stop() }
        let connection = try await WebSocketConnector().connect(
            to: .host("127.0.0.1", port: server.port), path: "/v1/ctl", policy: .pinned(server.certificateSHA256),
            timeout: .seconds(5))
        let serverChannel = try #require(await server.accept())
        let envelope = #"{"v":1,"type":"clipboard","id":"a","ts":1,"payload":"LAN"}"#
        try await connection.channel.send(.bulkText(envelope))
        #expect(try await serverChannel.receive() == .text(envelope))
        await connection.channel.close(code: .normal)
    }
}

/// Đếm các lần `set`, an toàn khi nhiều task cùng gọi.
final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var indexes: Set<Int> = []
    func set(_ index: Int) { lock.withLock { _ = indexes.insert(index) } }
    var count: Int { lock.withLock { indexes.count } }
    var isEmpty: Bool { lock.withLock { indexes.isEmpty } }
}

/// Ghi lại mọi `write`; lần ghi đầu tiên dừng lại cho đến khi `release()` (một liên kết đang bận), các lần sau qua ngay.
final class GateStream: BluetoothByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [Data] = []
    private var parked: CheckedContinuation<Void, Never>?
    private var released = false
    private var reader: CheckedContinuation<Data, Error>?
    private var closed = false

    var writeCount: Int { lock.withLock { written.count } }

    func write(_ data: Data) async throws {
        let mustPark = lock.withLock {
            written.append(data)
            return written.count == 1 && !released
        }
        guard mustPark else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if released { return true }
                parked = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock {
            released = true
            defer { parked = nil }
            return parked
        }
        waiting?.resume()
    }

    /// Chờ tới 2 giây cho đến khi đã có ít nhất `count` lần ghi.
    func waitForWrites(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if writeCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return writeCount >= count
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
        let parkedReader = lock.withLock {
            closed = true
            defer { reader = nil }
            return reader
        }
        parkedReader?.resume(throwing: ChannelClosed(code: nil, detail: "closed"))
        release()
    }

    func decodedFrames(sealKey: Data) throws -> [BtTransportFrame] {
        let cipher = BtTransportCipher(initialKey: sealKey)
        return try lock.withLock {
            try written.map { record in
                let rlen = BtRecordCodec.decodeRlen(record.subdata(in: 0..<BtRecordCodec.lengthPrefixSize))
                let sealed = record.subdata(in: BtRecordCodec.lengthPrefixSize..<(BtRecordCodec.lengthPrefixSize + rlen))
                return try BtTransportFrame.decode(try cipher.open(sealed))
            }
        }
    }
}
