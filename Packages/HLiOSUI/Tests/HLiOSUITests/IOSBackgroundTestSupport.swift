import Foundation
import HLTransport
@testable import HLiOSUI

/// Background tasks as a script: refuse, report the time left, fire the expiration handler.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskProviding {
    var refuses = false
    var remaining: Duration?
    private(set) var begun: [BackgroundTaskToken] = []
    private(set) var ended: [BackgroundTaskToken] = []
    private var handlers: [BackgroundTaskToken: @MainActor @Sendable () -> Void] = [:]
    private var next = 1

    func begin(name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? {
        guard !refuses else { return nil }
        let token = BackgroundTaskToken(raw: next)
        next += 1
        begun.append(token)
        handlers[token] = expiration
        return token
    }

    func end(_ token: BackgroundTaskToken) {
        ended.append(token)
    }

    /// The system's time is up for every task still running.
    func expire() {
        for token in begun where !ended.contains(token) { handlers[token]?() }
    }
}

/// The connection as the background logic drives it: every sleep and wake in order.
actor RecordingLifecycle: ConnectionLifecycle {
    private(set) var log: [String] = []

    func systemWillSleep() async { log.append("sleep") }
    func systemDidWake() async { log.append("wake") }
}

/// Polls an async `condition` for up to three seconds.
@MainActor
func eventuallyAsync(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A connection whose close hangs (a stalled `bye`) until the test releases it.
actor HangingLifecycle: ConnectionLifecycle {
    private(set) var log: [String] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func systemWillSleep() async {
        log.append("sleep")
        await withCheckedContinuation { waiting.append($0) }
        log.append("closed")
    }

    func systemDidWake() async { log.append("wake") }

    func release() {
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
