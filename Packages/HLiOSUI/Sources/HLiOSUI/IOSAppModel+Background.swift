import Foundation
import HLAppCore
import HLTransport

/// What the background logic asks of the connection: `ConnectionManager` in the app, a recorder in tests.
protocol ConnectionLifecycle: Sendable {
    /// `session/bye {shutdown}`, close, and no new session until `systemDidWake`.
    func systemWillSleep() async
    /// Run CONN-01 at once if there is no session.
    func systemDidWake() async
}

extension ConnectionManager: ConnectionLifecycle {}

/// The session in the background (CONN-02 E3): who holds it, the grace of `IOS_BACKGROUND_GRACE`, and the queue that
/// runs closes and reopens in order.
struct ConnectionHold {
    struct Grace {
        let token: BackgroundTaskToken
        let generation: Int
        let timer: Task<Void, Never>
    }

    /// The grace and every notification action that needs the phone; the session closes in the background at 0.
    var holders = 0
    /// The connection was told `systemWillSleep` and not woken since.
    var asleep = false
    var grace: Grace?
    /// Bumped on every scene change: a grace of an older background stint never closes a newer session.
    var generation = 0
    /// The last close or reopen; the next one waits for it, so a wake never overtakes the sleep before it.
    var queue: Task<Void, Never>?
    /// Stands in for the connection manager in tests.
    var lifecycle: (any ConnectionLifecycle)?
}

/// Why a grace ended (HLBENCH `grace_end reason=`).
enum GraceEnd: String {
    case deadline, expired, foreground, dropped
}

extension IOSAppModel {
    // MARK: - Scene phase (CONN-02 E3, CLIP-04 step 2)

    /// The scene became active: reconnect, look at the clipboard's `changeCount`, remove stale incoming-call
    /// notifications, re-read the notification state.
    public func sceneBecameActive() {
        inForeground = true
        hold.generation += 1
        endGrace(reason: .foreground) // the session stays: no `bye`
        clipboard?.localChangeSeen()
        messages?.setActive(true)
        calls.becameActive()
        let wake = wakeConnection()
        Task {
            await wake.value
            notificationPermission = await notifications.permission()
            timeSensitive = await notifications.timeSensitive()
        }
    }

    /// The scene went to the background: the session stays for the grace (CONN-02 E3), then `session/bye {shutdown}`
    /// and no session until it comes back; SMS and calls then arrive through push (CONN-04). `.inactive` (Control
    /// Center, the app switcher, Face ID) never gets here.
    public func sceneEnteredBackground() {
        inForeground = false
        messages?.setActive(false)
        beginGrace()
    }

    /// Margin before the system's own deadline, so `session/bye` goes out while the app still runs.
    static let backgroundMargin: Duration = .seconds(5)

    /// CONN-02 E3: the app left the foreground with a live session. A background task keeps it for `min(grace, time
    /// left − 5 s)`; refused, or without a session, it closes at once.
    func beginGrace() {
        hold.generation += 1
        guard hold.grace == nil, case .connected = link.status else {
            closeIfUnheld()
            return
        }
        let generation = hold.generation
        let token = backgroundTasks.begin(name: "HandLive session") { [weak self] in
            self?.endGrace(generation: generation, reason: .expired)
        }
        guard let token else {
            closeIfUnheld()
            return
        }
        let systemLimit = backgroundTasks.remaining.map { $0 - Self.backgroundMargin } ?? backgroundGrace
        let wait = max(.zero, min(backgroundGrace, systemLimit))
        let timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.endGrace(generation: generation, reason: .deadline)
        }
        hold.holders += 1
        hold.grace = ConnectionHold.Grace(token: token, generation: generation, timer: timer)
        clipboard?.protectLocalContent(true)
        BenchLog.event("grace_begin", ["wait_ms": String(Int(wait / .milliseconds(1)))])
        calls.graceStarted()
    }

    /// Ends the grace of `generation` (any grace when `nil`) and gives up its hold; a notification action still holding
    /// the session keeps it under its own task. At the deadline the task ends once the `bye` went out; when the
    /// system's time is up (the expiration handler must not wait), the session dropped or the app is back, at once.
    func endGrace(generation: Int? = nil, reason: GraceEnd) {
        guard let grace = hold.grace, generation == nil || generation == grace.generation else { return }
        hold.grace = nil
        grace.timer.cancel()
        hold.holders = max(0, hold.holders - 1)
        clipboard?.protectLocalContent(false)
        BenchLog.event("grace_end", ["reason": reason.rawValue])
        let closing = closeIfUnheld()
        guard reason == .deadline, let closing else { return backgroundTasks.end(grace.token) }
        let tasks = backgroundTasks
        Task {
            await closing.value
            tasks.end(grace.token)
        }
    }

    /// The session ended during the grace: the grace lets go at once, the task ends, no new session in the background
    /// (and no `bye` on the dead one: `systemWillSleep` only stops the reconnecting).
    func sessionDroppedInBackground() {
        guard hold.grace != nil else { return }
        endGrace(reason: .dropped)
    }

    /// A notification action needs the phone: the session stays (or comes back) until `releaseConnection`.
    func holdConnection() async {
        hold.holders += 1
        if hold.asleep { await wakeConnection().value }
    }

    /// The action is done: in the background, the last holder closes the session (`session/bye` sent before return).
    func releaseConnection() async {
        hold.holders = max(0, hold.holders - 1)
        await closeIfUnheld()?.value
    }

    /// Closes the session when nobody holds it and the app is not in the foreground.
    @discardableResult
    func closeIfUnheld() -> Task<Void, Never>? {
        guard hold.holders == 0, !inForeground, !hold.asleep else { return nil }
        hold.asleep = true
        calls.enteredBackground()
        return enqueueConnection { await $0.systemWillSleep() }
    }

    /// The scene is active again, or an action woke the app: run CONN-01 now if there is no session. Queued behind a
    /// close already under way, so CONN-01 starts once the old session is closed (never a 4409 to itself).
    @discardableResult
    func wakeConnection() -> Task<Void, Never> {
        hold.asleep = false
        return enqueueConnection { await $0.systemDidWake() }
    }

    private func enqueueConnection(_ step: @escaping @Sendable (any ConnectionLifecycle) async -> Void)
        -> Task<Void, Never> {
        let previous = hold.queue
        let target: (any ConnectionLifecycle)? = hold.lifecycle ?? manager
        let task = Task {
            await previous?.value
            if let target { await step(target) }
        }
        hold.queue = task
        return task
    }

    /// SMS and calls that reach the app during the grace come over the session, not through push: the app shows them
    /// the way the extension shows a push (CONN-04).
    var notifiesInBackground: Bool { hold.grace != nil }
}
