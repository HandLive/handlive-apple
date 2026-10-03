import Foundation
import HLCrypto
import HLProtocol

/// What the pairing sheet shows while the search runs (PAIR-01 field 8).
public enum PairingProgress: Sendable, Equatable {
    /// `waiting_scan`: the code is shown, no pairing window of the phone is visible yet.
    case waitingForPhone
    /// The phone's window is visible; opening `/v1/pair`.
    case connecting
    /// `verifying`: `pair/hello` sent; with a PIN the phone answers once the user typed it.
    case verifying
    /// SET-03 E4 / CONN-01 E8: the browser is refused local network access.
    case localNetworkDenied
    /// E3: the phone's window has been visible for 20 s but no connection to it worked.
    case phoneUnreachable
}

/// Runs one pairing search per code; the pairing screen depends on this so tests can script it.
public protocol PairingSearching: Sendable {
    func run(identity: PairingIdentity, credential: PairingCredential, offerTimeout: Duration,
             progress: @escaping @Sendable (PairingProgress) -> Void) async throws -> PairingResult
}

/// Finds the phone's pairing window on the LAN, or meets it in the relay rendezvous of the QR code, and runs the
/// exchange (PAIR-01 steps 7–11, A2–A5): an instance whose TXT `pr` matches this QR code, or any instance with `pm = 1`
/// for a PIN; the rendezvous only when no window is visible on the LAN. Dropped connections, `PAIRING_CLOSED`
/// and connection errors are retried while the window stays visible; a pair, `AUTH_FAILED` and a wrong PIN end the
/// search. Cancel the calling task to stop it (a new code, Cancel).
public struct PairingSearch: PairingSearching {
    public let discovery: any LANDiscovering
    public let connector: any ChannelConnecting
    /// Short so stale Bonjour ghosts fail fast and the live instance is tried (PAIR-01 E3).
    public var connectTimeout: Duration = .seconds(2)
    public var retryDelay: Duration = .seconds(1)
    /// PAIR-01 step 7: "Waits up to 20 s".
    public var unreachableAfter: Duration = .seconds(20)
    /// `K_pin` parameters (0.6.2); tests use smaller ones.
    public var pinParameters = Argon2id.Parameters.pairingPIN

    public init(discovery: any LANDiscovering, connector: any ChannelConnecting) {
        self.discovery = discovery
        self.connector = connector
    }

    public func run(identity: PairingIdentity, credential: PairingCredential, offerTimeout: Duration,
                    progress: @escaping @Sendable (PairingProgress) -> Void) async throws -> PairingResult {
        let board = PhoneBoard(matching: Self.matcher(identity: identity, credential: credential),
                               fallbackEligible: Self.fallbackEligible(credential: credential))
        let (changes, notify) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watcher = Task { [discovery] in
            for await event in discovery.events() {
                board.apply(event)
                notify.yield()
            }
            notify.finish()
        }
        defer { watcher.cancel() }
        let rendezvousWatcher = Self.watchRendezvous(credential, board: board, notify: notify)
        defer { rendezvousWatcher?.cancel() }
        let reporter = ProgressReporter(progress)
        var exchange = PairingExchange(identity: identity, credential: credential, offerTimeout: offerTimeout)
        exchange.pinParameters = pinParameters
        var iterator = changes.makeAsyncIterator()
        var failedNames = Set<String>()
        reporter.report(.waitingForPhone)
        while true {
            try Task.checkCancellation()
            // Keep failures for every instance still visible (matching or not); ghosts often lose `pr` briefly.
            failedNames = failedNames.intersection(board.visibleNames)
            // Prefer TXT match; if every match is a ghost, try any protocol-v1 phone (exchange rejects wrong peers).
            guard let (phone, seenSince, viaFallback) = board.nextAttempt(excluding: failedNames) else {
                if let result = try await Self.pairThroughRendezvous(credential, board: board, exchange: exchange,
                                                                      reporter: reporter) {
                    return result
                }
                if board.denied {
                    reporter.report(.localNetworkDenied)
                } else if let earliest = board.earliestSeen(), !board.wasReached,
                          earliest.duration(to: .now) >= unreachableAfter {
                    reporter.report(.phoneUnreachable)
                } else if failedNames.isEmpty {
                    reporter.report(.waitingForPhone)
                }
                if !board.visibleNames.isEmpty, board.visibleNames.isSubset(of: failedNames) {
                    // Every visible instance failed to connect (a transient drop, not a protocol failure). Wait, then
                    // clear the blacklist so they are retried while they stay visible, instead of spinning forever
                    // (PAIR-01 A2: the search keeps trying the window until it pairs or the caller's window closes).
                    try await Task.sleep(for: retryDelay)
                    failedNames.removeAll()
                } else {
                    guard await iterator.next() != nil else { throw CancellationError() }
                }
                continue
            }
            reporter.report(.connecting)
            do {
                let connection = try await connector.connect(to: .service(phone.endpoint), path: TransportConstants.pairPath,
                                                             policy: .recordAny, timeout: connectTimeout)
                reporter.report(.verifying)
                board.reached()
                let result = try await exchange.run(over: connection.channel,
                                                    certificateSHA256: connection.certificateSHA256)
                return result.withLAN(host: connection.host, port: connection.port)
            } catch let failure as PairingFailure where Self.isRetryable(failure) {
                // Window closed / dropped: keep trying this instance; do not blacklist it as a ghost.
                if !board.wasReached, seenSince.duration(to: .now) >= unreachableAfter {
                    reporter.report(.phoneUnreachable)
                }
                try await Task.sleep(for: retryDelay)
            } catch let failure as PairingFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedNames.insert(phone.name)
                if !board.wasReached, seenSince.duration(to: .now) >= unreachableAfter {
                    reporter.report(.phoneUnreachable)
                }
                if board.nextAttempt(excluding: failedNames) == nil {
                    try await Task.sleep(for: retryDelay)
                }
            }
        }
    }

    /// The exchange inside `rv_msg` once the phone joined, only while the LAN shows no window: the LAN wins (step 7).
    /// `nil` when the rendezvous is not ready or failed in a way the LAN may still recover from.
    static func pairThroughRendezvous(_ credential: PairingCredential, board: PhoneBoard, exchange: PairingExchange,
                                      reporter: ProgressReporter) async throws -> PairingResult? {
        guard board.rendezvousReady, case .qr(_, let rendezvous?) = credential else { return nil }
        reporter.report(.verifying)
        board.reached()
        do {
            return try await exchange.run(over: rendezvous.channel, certificateSHA256: nil)
        } catch let failure as PairingFailure where !isRetryable(failure) {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            board.rendezvousSpent() // one exchange per rendezvous
            return nil
        }
    }

    /// Waits for the phone in the rendezvous of the QR code, if it has one (PAIR-01 step 7, relay path).
    static func watchRendezvous(_ credential: PairingCredential, board: PhoneBoard,
                                notify: AsyncStream<Void>.Continuation) -> Task<Void, Never>? {
        guard case .qr(_, let rendezvous?) = credential else { return nil }
        return Task {
            if await rendezvous.waitForPhone() {
                board.markRendezvousReady()
                notify.yield()
            }
        }
    }

    static func isRetryable(_ failure: PairingFailure) -> Bool {
        switch failure {
        case .pairingClosed, .disconnected, .rejected: true
        case .authFailed, .pinInvalid: false
        }
    }

    /// QR: TXT `pr` = the first 8 hex digits of SHA-256(`pk`); PIN: `pm = 1`. Both need `v = 1`.
    static func matcher(identity: PairingIdentity,
                        credential: PairingCredential) -> @Sendable (DiscoveredPhone) -> Bool {
        switch credential {
        case .qr:
            let hint = PairingAuthDerivation.pairingRequestHint(clientDHPublicKey: identity.dhPublicKey)
            return { $0.speaksProtocolV1 && $0.pairingKeyHash?.lowercased() == hint }
        case .pin:
            return { $0.speaksProtocolV1 && $0.pinPairingOpen }
        }
    }

    /// Whether a non-matching instance may still be the target so the search may fall back to it: only when the
    /// relevant TXT hint is *absent* (the live advertiser's `pr`/`pm` is briefly missing from the Mac's cache). An
    /// instance that advertises a *different* `pr`, or a `pm` that is not `1`, is another device/state and is skipped
    /// (PAIR-01 A2): connecting to it would leak the pairing attempt to the wrong phone.
    static func fallbackEligible(credential: PairingCredential) -> @Sendable (DiscoveredPhone) -> Bool {
        switch credential {
        case .qr:
            return { $0.speaksProtocolV1 && $0.pairingKeyHash == nil }
        case .pin:
            return { $0.speaksProtocolV1 && $0.txt["pm"] == nil }
        }
    }
}

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
    func nextAttempt(excluding: Set<String>) -> (DiscoveredPhone, ContinuousClock.Instant, Bool)? {
        lock.lock()
        defer { lock.unlock() }
        if let match = Self.pick(matching, excluding: excluding, firstSeen: firstSeen, newest: false) {
            return (match.0, match.1, false)
        }
        if let fallback = Self.pick(visible.filter(canFallBack), excluding: excluding, firstSeen: firstSeen, newest: true) {
            return (fallback.0, fallback.1, true)
        }
        return nil
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
