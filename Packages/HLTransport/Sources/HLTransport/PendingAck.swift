import Foundation
import HLProtocol

/// The `ack` a request is waiting for. The session resolves it when the `ack` arrives or when the session ends;
/// the caller starts the timeout when it starts waiting, so a chunked `clipboard/push` counts
/// `REQUEST_TIMEOUT` from its last chunk (CLIP-03 API 3 logic 3).
public final class PendingAck: @unchecked Sendable {
    /// `id` of the request envelope (`re` of the `ack`).
    public let requestId: String
    private let lock = NSLock()
    private var result: Result<Ack, Error>?
    private var continuation: CheckedContinuation<Ack, Error>?

    init(requestId: String) {
        self.requestId = requestId
    }

    /// Resolves once; later calls are ignored.
    func resolve(_ outcome: Result<Ack, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    /// Waits for the `ack`; throws `SessionError.timedOut` after `timeout`, `SessionError.ended` when the session
    /// ends first.
    public func response(timeout: Duration) async throws -> Ack {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.resolve(.failure(SessionError.timedOut)) }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Ack, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                waiting.resume(with: result)
            } else {
                continuation = waiting
                lock.unlock()
            }
        }
    }
}
