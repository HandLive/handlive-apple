import Foundation
import HLCrypto
import HLProtocol

/// `MessageChannel` over an open, link-secured Bluetooth connection (0.4.5 "Transport records and channels"):
/// turns `ChannelMessage`s into `chan`-multiplexed, Noise-encrypted records over a `BluetoothByteStream`, using
/// the scheduler/cipher/reassembler already built and vector-tested in M7.1b. `sealKey`/`openKey` are `c1`/`c2`
/// of the link-security handshake (0.4.5 step 4) — which one encrypts and which decrypts depends on the role:
/// C (this device, M-APP) seals with `c1` and opens with `c2`; a test fake playing S does the opposite, so this
/// type itself is role-agnostic.
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
    private actor Writer {
        private let stream: any BluetoothByteStream
        private let cipher: BtTransportCipher
        private let scheduler = BluetoothLinkScheduler()
        private var draining = false
        private var drainWaiters: [CheckedContinuation<Void, Error>] = []

        init(stream: any BluetoothByteStream, cipher: BtTransportCipher) {
            self.stream = stream
            self.cipher = cipher
        }

        func send(_ message: ChannelMessage) async throws {
            switch message {
            case .text(let envelope):
                let data = Data(envelope.utf8)
                let type = (try? Envelope.parse(data))?.type.rawValue ?? ""
                scheduler.enqueueControlEnvelope(type: type, envelope: data)
            case .binary(let data):
                scheduler.enqueueBulk(data)
            }
            if draining {
                try await withCheckedThrowingContinuation { drainWaiters.append($0) }
                return
            }
            draining = true
            do {
                while let plaintext = scheduler.poll() {
                    let sealed = try cipher.seal(plaintext)
                    try await stream.write(BtRecordCodec.encode(sealed))
                    scheduler.onDrained()
                }
                finishDrain(with: nil)
            } catch {
                finishDrain(with: error)
                throw error
            }
        }

        private func finishDrain(with error: Error?) {
            draining = false
            let waiters = drainWaiters
            drainWaiters = []
            for waiter in waiters {
                if let error { waiter.resume(throwing: error) } else { waiter.resume() }
            }
        }
    }

    /// Reads records until the stream closes or one violates a 0.4.5 bound (treated the same as a connection
    /// loss, CONN-05 E8: close the link without an answer, no reason given over the air).
    private static func readLoop(stream: any BluetoothByteStream, openCipher: BtTransportCipher,
                                 inbox: ChannelInbox) async {
        var bulkBuffer = Data()
        let reassembler = BluetoothLongLaneReassembler()
        do {
            while true {
                let rlen = BtRecordCodec.decodeRlen(try await stream.read(BtRecordCodec.lengthPrefixSize))
                try BtRecordCodec.requireValidTransportRlen(rlen)
                let ciphertextTag = try await stream.read(rlen)
                let plaintext = try openCipher.open(ciphertextTag)
                let frame = try BtTransportFrame.decode(plaintext)
                switch frame.chan {
                case BtLinkConstants.chanBulk:
                    bulkBuffer.append(frame.data)
                    if !frame.more {
                        inbox.deliver(.binary(bulkBuffer))
                        bulkBuffer = Data()
                    }
                default:
                    if frame.long {
                        if let message = try reassembler.accept(frame) {
                            inbox.deliver(.text(String(decoding: message, as: UTF8.self)))
                        }
                    } else {
                        inbox.deliver(.text(String(decoding: frame.data, as: UTF8.self)))
                    }
                }
            }
        } catch {
            inbox.close(ChannelClosed(code: nil, detail: "receive: \(error)"))
        }
    }
}
