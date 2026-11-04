import Foundation
import HLCrypto
import HLProtocol

/// `MessageChannel` over an open, link-secured Bluetooth connection (0.4.5 "Transport records and channels"):
/// turns `ChannelMessage`s into `chan`-multiplexed, Noise-encrypted records over a `BluetoothByteStream`, using
/// the scheduler/cipher/reassembler already built and vector-tested in M7.1b. `sealKey`/`openKey` are `c1`/`c2`
/// of the link-security handshake (0.4.5 step 4) — which one encrypts and which decrypts depends on the role:
/// C (this device, M-APP) seals with `c1` and opens with `c2`; a test fake playing S does the opposite, so this
/// type itself is role-agnostic.
///
/// Bulk lane (0.4.7): `.bulkText` travels on channel `0x02` with `BT_BULK_QUEUED` backpressure (rule 4);
/// `.binary` is rejected (rule 6, the HL frame of 0.5.2 never travels on Bluetooth); reassembled bulk
/// messages are handed up as `.text` (rule 6) through the same decryption, `DEDUP_WINDOW` and dispatcher as
/// the control channel.
public final class BluetoothChannel: MessageChannel, @unchecked Sendable {
    private let stream: any BluetoothByteStream
    private let writer: Writer
    private let inbox = ChannelInbox()
    private var readTask: Task<Void, Never>?

    public init(stream: any BluetoothByteStream, sealKey: Data, openKey: Data) {
        self.stream = stream
        writer = Writer(stream: stream, cipher: BtTransportCipher(initialKey: sealKey))
        let openCipher = BtTransportCipher(initialKey: openKey)
        readTask = Task { [inbox, stream] in
            await Self.readLoop(stream: stream, openCipher: openCipher, inbox: inbox)
        }
    }

    public func receive() async throws -> ChannelMessage {
        try await inbox.receive()
    }

    public func send(_ message: ChannelMessage) async throws {
        do {
            try await writer.send(message)
        } catch {
            let closed = ChannelClosed(code: nil, detail: "send: \(error)")
            inbox.close(closed)
            throw closed
        }
    }

    /// Số phong bì bulk đang xếp hàng mà chưa ghi xong (0.4.7 bulk rule 4): `send(.bulkText)` chặn khi đạt
    /// `BT_BULK_QUEUED`. `0` khi không có phong bì bulk nào đang chờ.
    public var pendingBulkEnvelopes: Int {
        get async { await writer.pendingBulkEnvelopes }
    }

    /// No transport-level ping/pong exists over an L2CAP link (0.4.5 has no record kind for it): a direct
    /// peer-to-peer connection's liveness is the OS connection state itself, already watched continuously by
    /// the read loop below. Reporting what that loop already knows is cheaper and just as accurate as waiting
    /// out `timeout` for a round trip that the wire format cannot express.
    public func ping(payload: Data, timeout: Duration) async throws {
        if let closed = inbox.closedReason { throw closed }
    }

    public func close(code: CloseCode) async {
        readTask?.cancel()
        await stream.close()
        inbox.close(ChannelClosed(code: code, detail: "closed locally", local: true))
    }

    /// Serializes the scheduler and the sealing cipher: `send(_:)` may be called concurrently (rekey alongside
    /// normal traffic, SMS and call-log sync at once), but the scheduler's queues and the cipher's record
    /// counter are not thread-safe on their own. Being an actor is not enough by itself: actors are reentrant,
    /// so a second `send` would run while the first is suspended in `stream.write` and start a second write on
    /// a stream that allows one writer at a time. So exactly one caller drains; later callers only enqueue and
    /// wait for that drain, which picks up their records too since it loops until the scheduler is empty.
    ///
    /// Bulk backpressure (0.4.7 bulk rule 4): `send(.bulkText)` blocks while `pendingBulkEnvelopes >=
    /// BT_BULK_QUEUED`. Waiters are resumed one at a time as each bulk envelope drains, so they race to
    /// enqueue and the losers re-wait.
    private actor Writer {
        private let stream: any BluetoothByteStream
        private let cipher: BtTransportCipher
        private let scheduler = BluetoothLinkScheduler()
        private var draining = false
        private var drainWaiters: [CheckedContinuation<Void, Error>] = []
        private var bulkBackpressureWaiters: [CheckedContinuation<Void, Error>] = []

        init(stream: any BluetoothByteStream, cipher: BtTransportCipher) {
            self.stream = stream
            self.cipher = cipher
        }

        var pendingBulkEnvelopes: Int { scheduler.pendingBulkEnvelopes }

        func send(_ message: ChannelMessage) async throws {
            // Bulk backpressure (0.4.7 bulk rule 4): chặn TRƯỚC khi xếp hàng, nếu đã đủ `BT_BULK_QUEUED` phong bì
            // bulk đang chờ. Mỗi lần một phong bì bulk xả xong, `resumeBulkBackpressureWaiter` đánh thức một
            // waiter; waiter đó sẽ xếp hàng rồi chờ drain hiện tại (nếu có) hoặc bắt đầu drain mới.
            if case .bulkText = message {
                while scheduler.pendingBulkEnvelopes >= BluetoothLinkConstants.bulkQueued {
                    try await withCheckedThrowingContinuation { bulkBackpressureWaiters.append($0) }
                }
            }

            switch message {
            case .text(let envelope):
                let data = Data(envelope.utf8)
                let type = (try? Envelope.parse(data))?.type.rawValue ?? ""
                scheduler.enqueueControlEnvelope(type: type, envelope: data)
            case .bulkText(let envelope):
                scheduler.enqueueBulk(Data(envelope.utf8))
            case .binary:
                // 0.4.7 bulk rule 6: `ChannelMessage.binary` là khung HL của 0.5.2, không bao giờ đi trên
                // Bluetooth. Ném lỗi để bên gọi biết sai lane.
                throw ChannelClosed(code: nil, detail: "binary not supported on Bluetooth", local: true)
            }
            if draining {
                try await withCheckedThrowingContinuation { drainWaiters.append($0) }
                return
            }
            draining = true
            do {
                while let next = scheduler.poll() {
                    let sealed = try cipher.seal(next.data)
                    try await stream.write(BtRecordCodec.encode(sealed))
                    scheduler.onDrained()
                    if next.isLastOfBulkEnvelope {
                        scheduler.onBulkEnvelopeDrained()
                        resumeBulkBackpressureWaiter()
                    }
                }
                finishDrain(with: nil)
            } catch {
                finishDrain(with: error)
                throw error
            }
        }

        private func finishDrain(with error: Error?) {
            draining = false
            let drainWaitersCopy = drainWaiters
            drainWaiters = []
            for waiter in drainWaitersCopy {
                if let error { waiter.resume(throwing: error) } else { waiter.resume() }
            }
            // Đánh thức mọi bulk backpressure waiter với cùng lỗi (nếu có) — kênh đã đóng thì không nên chờ nữa.
            let bulkWaiters = bulkBackpressureWaiters
            bulkBackpressureWaiters = []
            for waiter in bulkWaiters {
                if let error { waiter.resume(throwing: error) } else { waiter.resume() }
            }
        }

        private func resumeBulkBackpressureWaiter() {
            guard !bulkBackpressureWaiters.isEmpty,
                  scheduler.pendingBulkEnvelopes < BluetoothLinkConstants.bulkQueued else { return }
            bulkBackpressureWaiters.removeFirst().resume()
        }
    }

    /// A complete message as the envelope text a WebSocket text frame would carry (an invalid sequence fails the
    /// envelope parse later, like the same bytes on `/v1/ctl`).
    private static func envelopeText(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Reads records until the stream closes or one violates a 0.4.5/0.4.7 bound (treated the same as a
    /// connection loss, CONN-05 E8: close the link without an answer, no reason given over the air).
    private static func readLoop(stream: any BluetoothByteStream, openCipher: BtTransportCipher,
                                 inbox: ChannelInbox) async {
        let bulkReassembler = BluetoothBulkReassembler()
        let longReassembler = BluetoothLongLaneReassembler()
        do {
            while true {
                let rlen = BtRecordCodec.decodeRlen(try await stream.read(BtRecordCodec.lengthPrefixSize))
                try BtRecordCodec.requireValidTransportRlen(rlen)
                let ciphertextTag = try await stream.read(rlen)
                let plaintext = try openCipher.open(ciphertextTag)
                let frame = try BtTransportFrame.decode(plaintext)
                switch frame.chan {
                case BtLinkConstants.chanBulk:
                    // 0.4.7 bulk rule 5: `long` = 1 trên `0x02` → đóng liên kết. `BtTransportFrame.decode`
                    // đã kiểm tra `dlen` ≤ `bulkFragmentMax`; reassembler kiểm tra tổng ≤ `messageMax`.
                    // 0.4.7 bulk rule 6: tin bulk hoàn chỉnh đi lên dưới dạng `.text` (cùng pipeline với control).
                    if let message = try bulkReassembler.accept(frame) {
                        inbox.deliver(.text(Self.envelopeText(message)))
                    }
                default:
                    if frame.long {
                        if let message = try longReassembler.accept(frame) {
                            inbox.deliver(.text(Self.envelopeText(message)))
                        }
                    } else {
                        inbox.deliver(.text(Self.envelopeText(frame.data)))
                    }
                }
            }
        } catch {
            inbox.close(ChannelClosed(code: nil, detail: "receive: \(error)"))
        }
    }
}
