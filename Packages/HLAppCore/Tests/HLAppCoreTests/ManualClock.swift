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

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    /// How many tasks are suspended in `sleep` right now.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id: UInt64 = lock.withLock {
            nextId += 1
            return nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
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

    /// Moves the time forward by `duration`, wakes every sleeper whose deadline it reaches, and lets them run.
    func advance(by duration: Duration) async {
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
        await Self.settle()
    }

    /// Waits until at least `count` tasks sleep on this clock, so an `advance` cannot run ahead of the code under test.
    /// It yields instead of sleeping: no real time is involved.
    func waitForSleepers(_ count: Int = 1) async -> Bool {
        for _ in 0..<100_000 {
            if sleeperCount >= count { return true }
            await Task.yield()
        }
        return sleeperCount >= count
    }

    /// Lets the tasks just woken run up to their next suspension.
    private static func settle() async {
        for _ in 0..<100 {
            await Task.yield()
        }
    }
}
