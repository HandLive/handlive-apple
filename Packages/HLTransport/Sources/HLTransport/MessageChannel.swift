import Foundation
import HLProtocol

/// A WebSocket message: text frames carry envelopes (0.5.1); binary frames carry HL frames (0.5.2).
public enum ChannelMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// Why a channel stopped: the peer's close code when there was one, or a transport error.
public struct ChannelClosed: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: CloseCode?
    /// Diagnostic text for logs (never shown to the user, never contains content).
    public let detail: String
    /// `true` when this side closed the channel.
    public let local: Bool

    public init(code: CloseCode?, detail: String, local: Bool = false) {
        self.code = code
        self.detail = detail
        self.local = local
    }

    public var description: String {
        "closed(\(code.map { String($0.rawValue) } ?? "-"), \(local ? "local" : "remote"), \(detail))"
    }
}

/// One WebSocket connection, already open. `WebSocketChannel` is the Network.framework implementation; tests
/// use an in-memory pair.
public protocol MessageChannel: AnyObject, Sendable {
    /// Next incoming message in order; throws `ChannelClosed` once the channel is closed (and on every call
    /// after that). Cancelling the calling task throws `CancellationError` and keeps later messages queued.
    func receive() async throws -> ChannelMessage
    /// Sends one message; returns once the transport took it.
    func send(_ message: ChannelMessage) async throws
    /// WebSocket ping with `payload`; throws when no pong arrives within `timeout` (CONN-02 API 1).
    func ping(payload: Data, timeout: Duration) async throws
    /// Closes with a code of 0.8.3; idempotent. Pending and later `receive()` calls throw `ChannelClosed`.
    func close(code: CloseCode) async
}

/// Queue of received messages with at most one waiting reader; shared by the channel implementations.
public final class ChannelInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [ChannelMessage] = []
    private var closure: ChannelClosed?
    private var waiter: (id: UInt64, continuation: CheckedContinuation<ChannelMessage, Error>)?
    private var nextWaiterID: UInt64 = 0

    public init() {}

    /// Adds a message, or hands it to the waiting reader.
    public func deliver(_ message: ChannelMessage) {
        lock.lock()
        guard closure == nil else { lock.unlock(); return }
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.continuation.resume(returning: message)
        } else {
            buffered.append(message)
            lock.unlock()
        }
    }

    /// Marks the channel closed; the first closure wins. Buffered messages are still read first.
    public func close(_ closed: ChannelClosed) {
        lock.lock()
        guard closure == nil else { lock.unlock(); return }
        closure = closed
        let waiting = buffered.isEmpty ? waiter : nil
        if waiting != nil { waiter = nil }
        lock.unlock()
        waiting?.continuation.resume(throwing: closed)
    }

    public var isClosed: Bool { closedReason != nil }

    /// How the channel closed, once it has.
    public var closedReason: ChannelClosed? {
        lock.lock()
        defer { lock.unlock() }
        return closure
    }

    private func makeWaiterID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextWaiterID += 1
        return nextWaiterID
    }

    public func receive() async throws -> ChannelMessage {
        let id = makeWaiterID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !buffered.isEmpty {
                    let message = buffered.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: message)
                } else if let closure {
                    lock.unlock()
                    continuation.resume(throwing: closure)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    precondition(waiter == nil, "one reader at a time")
                    waiter = (id, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let cancelled = waiter?.id == id ? waiter : nil
            if cancelled != nil { waiter = nil }
            lock.unlock()
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }
}
