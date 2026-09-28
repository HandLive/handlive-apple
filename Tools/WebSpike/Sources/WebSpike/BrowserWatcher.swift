import AppKit
import WebSpikeCore

/// `watch`: follows the frontmost app; while it is a supported browser and the session is active, polls its front
/// window every `interval` seconds (`WEB_POLL_MAC`), and logs `active` once a page has settled, `private` for private
/// windows, and `inactive` when the browser is deactivated, the screen locks, the Mac sleeps or the page turns
/// private or unsupported (W4).
@MainActor
final class BrowserWatcher {
    private let log: EventLog
    private let interval: Double
    private let reader = AppleEventReader()
    private var timer: Timer?
    private var browser: (spec: BrowserSpec, pid: pid_t)?
    private var gate = SettleGate<String>()
    private var current: (browser: String, hash: String)?
    private var lastError: Int?
    private var loggedPrivate: String?
    private var polls = 0
    private var scriptMilliseconds = 0.0
    private var observers: [NSObjectProtocol] = []

    init(log: EventLog, interval: Double) {
        self.log = log
        self.interval = interval
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.frontmostChanged() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.stop(reason: "session_inactive") }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.frontmostChanged() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.stop(reason: "screen_sleep") }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.stop(reason: "sleep") }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.frontmostChanged() }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.stop(reason: "locked") }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.frontmostChanged() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { self.logStats() }
        }
        log.write(["ev": "started", "os": ProcessInfo.processInfo.operatingSystemVersionString, "interval": interval])
        frontmostChanged()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (BrowserWatcher) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        })
    }

    private func frontmostChanged() {
        let app = NSWorkspace.shared.frontmostApplication
        guard let app, let spec = BrowserTable.spec(forBundleID: app.bundleIdentifier) else {
            stop(reason: "deactivated")
            return
        }
        if browser?.pid == app.processIdentifier, timer != nil { return }
        stop(reason: "switched")
        browser = (spec, app.processIdentifier)
        lastError = nil
        let (permission, status) = AppleEventReader.permission(for: spec.bundleID)
        log.write(["ev": "frontmost", "browser": spec.wireID, "automation": permission.rawValue, "status": status])
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.poll() }
        }
    }

    private func stop(reason: String) {
        timer?.invalidate()
        timer = nil
        browser = nil
        endPage(reason: reason)
    }

    private func poll() {
        guard let (spec, pid) = browser else { return }
        polls += 1
        switch reader.read(spec) {
        case let .failure(code, milliseconds):
            scriptMilliseconds += milliseconds
            if code != lastError {
                lastError = code
                log.write(["ev": "error", "browser": spec.wireID, "code": code, "script_ms": rounded(milliseconds)])
            }
            endPage(reason: "error")
        case let .reading(reading, milliseconds):
            scriptMilliseconds += milliseconds
            lastError = nil
            handle(reading, spec: spec, pid: pid, milliseconds: milliseconds)
        }
    }

    private func handle(_ reading: PageReading, spec: BrowserSpec, pid: pid_t, milliseconds: Double) {
        guard let url = URLNormalizer.normalize(reading.url) else {
            _ = gate.observe(nil, now: now())
            endPage(reason: "unsupported") // new tab page, about:blank, favorites, chrome:// …
            return
        }
        guard let due = gate.observe(spec.wireID + " " + url.url, now: now()) else { return }
        var evidence: SafariPrivateProbe.Evidence?
        if spec.family == .safari {
            evidence = SafariPrivateProbe.probe(pid: pid, scripted: reading.safariBounds)
        }
        let verdict = reading.verdict(family: spec.family, safariProbe: evidence?.verdict)
        let boundsMatch = evidence?.boundsMatch
        let axState = evidence.map { $0.axTrusted ? "trusted" : "untrusted" }
        if case let .privateMode(marker) = verdict {
            if current != nil { endPage(reason: "private") }
            if loggedPrivate != due {
                loggedPrivate = due
                log.write(["ev": "private", "browser": spec.wireID, "private": "true", "marker": marker,
                           "script_ms": rounded(milliseconds), "bounds_match": boundsMatch, "ax": axState])
            }
            return
        }
        let hash = LogLine.hash(url.url, salt: log.salt)
        current = (spec.wireID, hash)
        log.write([
            "ev": "active", "browser": spec.wireID, "host": url.host, "hash": hash, "private": verdict.logValue,
            "mode": reading.mode.isEmpty || spec.family == .safari ? nil : reading.mode,
            "title_len": reading.title.count, "script_ms": rounded(milliseconds),
            "bounds_match": boundsMatch, "ax": axState,
        ])
    }

    /// `web/inactive` in the product.
    private func endPage(reason: String) {
        gate.reset()
        guard let (browserID, hash) = current else { return }
        current = nil
        log.write(["ev": "inactive", "browser": browserID, "hash": hash, "reason": reason])
    }

    func logStats() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        log.write(["ev": "stats", "polls": polls, "script_ms": rounded(scriptMilliseconds), "cpu_ms": rounded(cpu)])
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
