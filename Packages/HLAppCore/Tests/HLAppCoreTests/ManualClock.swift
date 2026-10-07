import Foundation

/// A clock that moves only when a test says so: `sleep` suspends until `advance(by:)` reaches its deadline, so the
/// outcome of timed code no longer depends on how busy the machine (or the MainActor) is.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        fileprivate var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<UInt64> = []
    private var nextId: UInt64 = 0
    /// Tests waiting in `waitForSleepers` for that many sleepers.
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id: UInt64 = lock.withLock {
            nextId += 1
            return nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (outcome, ready): (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
                    if cancelled.remove(id) != nil { return (.failure(CancellationError()), []) }
                    if deadline <= current { return (.success(()), []) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return (nil, takeReadyWaiters())
                }
                if let outcome { continuation.resume(with: outcome) }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id) // cancelled before it was suspended: it throws as soon as it is
                    return nil
                }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the time forward by `duration` and wakes every sleeper whose deadline it reaches.
    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let now = current
            let due = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Waits until at least `count` tasks sleep on this clock, so an `advance` cannot run ahead of the code under test.
    /// It is woken by the sleepers themselves, never by real time: however slow the machine, it waits for them.
    func waitForSleepers(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.withLock {
                guard sleepers.count < count else { return true }
                waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// The waiters whose count of sleepers is reached, removed from the list; call it with the lock held.
    private func takeReadyWaiters() -> [CheckedContinuation<Void, Never>] {
        let ready = waiters.filter { $0.count <= sleepers.count }.map(\.continuation)
        waiters.removeAll { $0.count <= sleepers.count }
        return ready
    }
}
