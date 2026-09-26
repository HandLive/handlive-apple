import Foundation
import HLProtocol
import Network

/// `MessageChannel` over a Network.framework WebSocket connection that is already `.ready`.
public final class WebSocketChannel: MessageChannel, @unchecked Sendable {
    // Mutable state is only touched on `queue`.
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let inbox = ChannelInbox()
    private var closed = false

    /// Takes over a ready connection and starts reading from it.
    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        queue.async { [self] in
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            receiveNext()
        }
    }

    public func receive() async throws -> ChannelMessage {
        try await inbox.receive()
    }

    public func send(_ message: ChannelMessage) async throws {
        let (opcode, data): (NWProtocolWebSocket.Opcode, Data) = switch message {
        case .text(let text): (.text, Data(text.utf8))
        case .binary(let data): (.binary, data)
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                guard let error else {
                    done.resume()
                    return
                }
                done.resume(throwing: ChannelClosed(code: nil, detail: "send: \(error)"))
            })
        }
    }

    public func ping(payload: Data, timeout: Duration) async throws {
        let pong = PongWaiter()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { error in pong.finish(error.map { ChannelClosed(code: nil, detail: "\($0)") }) }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { pong.finish(ChannelClosed(code: nil, detail: "ping: \(error)")) }
        })
        try await pong.wait(timeout: timeout)
    }

    public func close(code: CloseCode) async {
        let alreadyClosed: Bool = queue.sync {
            defer { closed = true }
            return closed
        }
        guard !alreadyClosed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code.nwCloseCode
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in done.resume() })
        }
        inbox.close(ChannelClosed(code: code, detail: "closed locally", local: true))
        queue.async { [self] in connection.cancel() }
    }

    // MARK: - Reading (on `queue`)

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                finish(ChannelClosed(code: nil, detail: "receive: \(error)"))
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                // Invalid UTF-8 becomes an empty text that no envelope parser accepts.
                inbox.deliver(.text(String(bytes: data ?? Data(), encoding: .utf8) ?? ""))
            case .binary?:
                inbox.deliver(.binary(data ?? Data()))
            case .close?:
                closed = true
                finish(ChannelClosed(code: metadata.map { CloseCode(nw: $0.closeCode) }, detail: "closed by peer"))
                connection.cancel()
                return
            default:
                break // ping/pong/cont frames are handled by the stack
            }
            if context?.isFinal == true && data == nil && metadata == nil {
                finish(ChannelClosed(code: nil, detail: "end of stream"))
                return
            }
            receiveNext()
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .failed(let error): finish(ChannelClosed(code: nil, detail: "failed: \(error)"))
        case .cancelled: finish(ChannelClosed(code: nil, detail: "cancelled"))
        default: break
        }
    }

    private func finish(_ closure: ChannelClosed) {
        inbox.close(closure)
    }
}

/// Resumes the ping caller exactly once: pong, send error, or timeout.
private final class PongWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func finish(_ error: Error?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let outcome: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        result = outcome
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    func wait(timeout: Duration) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(ChannelClosed(code: nil, detail: "no pong within \(timeout)"))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

extension CloseCode {
    var nwCloseCode: NWProtocolWebSocket.CloseCode {
        rawValue == 1000 ? .protocolCode(.normalClosure) : .privateCode(rawValue)
    }

    init(nw code: NWProtocolWebSocket.CloseCode) {
        switch code {
        case .protocolCode(let defined): self.init(rawValue: defined.rawValue)
        case .applicationCode(let value), .privateCode(let value): self.init(rawValue: value)
        @unknown default: self = .other(0)
        }
    }
}
