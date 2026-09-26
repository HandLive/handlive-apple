import Foundation

/// Why the connection manager's loop should look again at its situation.
enum ManagerSignal: Sendable, Equatable {
    case phoneChanged
    case network
    case discovery
    case reconnectNow
    case sleep
    case wake
    /// The session with this token ended; an older session's end is ignored.
    case sessionEnded(SessionEnd, token: UInt64)
    case pairRevoked(token: UInt64)
    /// An event of the relay connection (presence, `pair_revoked`, errors, closed).
    case relay(RelayLinkEvent)
    case relaySettingChanged
}

/// Signals queued for the manager's loop, which waits for the next one with an optional timeout.
final class SignalQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [ManagerSignal] = []
    private var waiter: (id: UInt64, continuation: CheckedContinuation<ManagerSignal?, Never>)?
    private var nextID: UInt64 = 0
    private var expiredEarly: Set<UInt64> = []

    func post(_ signal: ManagerSignal) {
        lock.lock()
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.continuation.resume(returning: signal)
        } else {
            queued.append(signal)
            lock.unlock()
        }
    }

    /// Drops queued signals that no longer matter (after the loop has looked at everything).
    func drain(keeping keep: (ManagerSignal) -> Bool) {
        lock.lock()
        queued.removeAll { !keep($0) }
        lock.unlock()
    }

    /// Next signal, or `nil` after `timeout` (never when `timeout` is `nil`) or on cancellation.
    func next(timeout: Duration?) async -> ManagerSignal? {
        let id = makeID()
        let timer = timeout.map { limit in
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { self?.expire(id) }
            }
        }
        defer {
            timer?.cancel()
            forget(id)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !queued.isEmpty {
                    let signal = queued.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: signal)
                } else if expiredEarly.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter = (id, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            expire(id)
        }
    }

    private func makeID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func forget(_ id: UInt64) {
        lock.lock()
        expiredEarly.remove(id)
        lock.unlock()
    }

    private func expire(_ id: UInt64) {
        lock.lock()
        let expired = waiter?.id == id ? waiter : nil
        if expired != nil {
            waiter = nil
        } else {
            expiredEarly.insert(id) // the timer won the race with the registration
        }
        lock.unlock()
        expired?.continuation.resume(returning: nil)
    }
}
