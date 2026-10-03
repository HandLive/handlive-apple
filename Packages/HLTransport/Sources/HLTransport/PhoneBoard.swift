import Foundation

/// Latest browse results and when each matching instance was first seen; whether the relay rendezvous is ready.
final class PhoneBoard: @unchecked Sendable {
    private let lock = NSLock()
    private let matches: @Sendable (DiscoveredPhone) -> Bool
    /// Whether a non-matching instance may still be the target (its TXT hint is absent, not wrong).
    private let canFallBack: @Sendable (DiscoveredPhone) -> Bool
    /// Every protocol-v1 phone currently browsed (including ghosts and non-matching TXT).
    private var visible: [DiscoveredPhone] = []
    private var matching: [DiscoveredPhone] = []
    private var firstSeen: [String: ContinuousClock.Instant] = [:]
    private var isDenied = false
    private var reachedOnce = false
    private var rendezvousState = 0 // 0 waiting, 1 phone joined, 2 used up

    init(matching: @escaping @Sendable (DiscoveredPhone) -> Bool,
         fallbackEligible: @escaping @Sendable (DiscoveredPhone) -> Bool) {
        matches = matching
        canFallBack = fallbackEligible
    }

    func apply(_ event: DiscoveryEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .results(let all):
            visible = all.filter(\.speaksProtocolV1)
            matching = visible.filter(matches)
            let names = Set(visible.map(\.name))
            firstSeen = firstSeen.filter { names.contains($0.key) }
            for name in names where firstSeen[name] == nil { firstSeen[name] = .now }
        case .state(let state):
            isDenied = state == .localNetworkDenied
        }
    }

    /// Next phone to try: TXT match first, then any other v1 instance (stale Bonjour ghosts often match TXT but
    /// never resolve; the live advertiser may briefly lack `pr`/`pm` in the Mac's cache).
    func nextAttempt(excluding: Set<String>) -> (DiscoveredPhone, ContinuousClock.Instant)? {
        lock.lock()
        defer { lock.unlock() }
        // Prefer a TXT match; otherwise any fallback-eligible instance (the live advertiser's hint is briefly absent).
        return Self.pick(matching, excluding: excluding, firstSeen: firstSeen, newest: false)
            ?? Self.pick(visible.filter(canFallBack), excluding: excluding, firstSeen: firstSeen, newest: true)
    }

    private static func pick(_ phones: [DiscoveredPhone], excluding: Set<String>,
                             firstSeen: [String: ContinuousClock.Instant],
                             newest: Bool) -> (DiscoveredPhone, ContinuousClock.Instant)? {
        let ranked = phones.filter { !excluding.contains($0.name) }
            .compactMap { phone in firstSeen[phone.name].map { (phone, $0) } }
        return newest ? ranked.max { $0.1 < $1.1 } : ranked.min { $0.1 < $1.1 }
    }

    /// Names of every protocol-v1 instance currently browsed.
    var visibleNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(visible.map(\.name))
    }

    /// When the first matching or visible instance appeared (for the E3 unreachable grace).
    func earliestSeen() -> ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        let names = Set(matching.map(\.name)).union(visible.map(\.name))
        return firstSeen.filter { names.contains($0.key) }.values.min()
    }

    var denied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDenied
    }

    var rendezvousReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rendezvousState == 1
    }

    func markRendezvousReady() {
        lock.lock()
        if rendezvousState == 0 { rendezvousState = 1 }
        lock.unlock()
    }

    func rendezvousSpent() {
        lock.lock()
        rendezvousState = 2
        lock.unlock()
    }

    /// A connection reached the phone once, so the window is not unreachable (E3).
    func reached() {
        lock.lock()
        reachedOnce = true
        lock.unlock()
    }

    var wasReached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedOnce
    }
}

/// Reports a progress value only when it changes.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: @Sendable (PairingProgress) -> Void
    private var last: PairingProgress?

    init(_ sink: @escaping @Sendable (PairingProgress) -> Void) {
        self.sink = sink
    }

    func report(_ value: PairingProgress) {
        lock.lock()
        let changed = last != value
        last = value
        lock.unlock()
        if changed { sink(value) }
    }
}
