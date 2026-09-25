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

/// Finds the phone's pairing window on the LAN and runs the exchange (PAIR-01 steps 7–11, A2–A5): an instance whose
/// TXT `pr` matches this QR code, or any instance with `pm = 1` for a PIN. Dropped connections, `PAIRING_CLOSED`
/// and connection errors are retried while the window stays visible; a pair, `AUTH_FAILED` and a wrong PIN end the
/// search. Cancel the calling task to stop it (a new code, Cancel).
public struct PairingSearch: Sendable {
    public let discovery: any LANDiscovering
    public let connector: any ChannelConnecting
    public var connectTimeout: Duration = .seconds(5)
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
        let board = PhoneBoard(matching: Self.matcher(identity: identity, credential: credential))
        let (changes, notify) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watcher = Task { [discovery] in
            for await event in discovery.events() {
                board.apply(event)
                notify.yield()
            }
            notify.finish()
        }
        defer { watcher.cancel() }
        let reporter = ProgressReporter(progress)
        var exchange = PairingExchange(identity: identity, credential: credential, offerTimeout: offerTimeout)
        exchange.pinParameters = pinParameters
        var iterator = changes.makeAsyncIterator()
        reporter.report(.waitingForPhone)
        while true {
            try Task.checkCancellation()
            guard let (phone, seenSince) = board.candidate() else {
                reporter.report(board.denied ? .localNetworkDenied : .waitingForPhone)
                guard await iterator.next() != nil else { throw CancellationError() }
                continue
            }
            reporter.report(.connecting)
            do {
                let connection = try await connector.connect(to: .service(phone.endpoint), path: TransportConstants.pairPath,
                                                             policy: .recordAny, timeout: connectTimeout)
                reporter.report(.verifying)
                board.reached()
                return try await exchange.run(over: connection.channel, certificateSHA256: connection.certificateSHA256)
            } catch let failure as PairingFailure where !Self.isRetryable(failure) {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !board.wasReached, seenSince.duration(to: .now) >= unreachableAfter {
                    reporter.report(.phoneUnreachable)
                }
                try await Task.sleep(for: retryDelay)
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
}

/// Latest browse results and when each matching instance was first seen.
private final class PhoneBoard: @unchecked Sendable {
    private let lock = NSLock()
    private let matches: @Sendable (DiscoveredPhone) -> Bool
    private var phones: [DiscoveredPhone] = []
    private var firstSeen: [String: ContinuousClock.Instant] = [:]
    private var isDenied = false
    private var reachedOnce = false

    init(matching: @escaping @Sendable (DiscoveredPhone) -> Bool) {
        matches = matching
    }

    func apply(_ event: DiscoveryEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .results(let all):
            phones = all.filter(matches)
            let names = Set(phones.map(\.name))
            firstSeen = firstSeen.filter { names.contains($0.key) }
            for name in names where firstSeen[name] == nil { firstSeen[name] = .now }
        case .state(let state):
            isDenied = state == .localNetworkDenied
        }
    }

    /// The matching instance seen first, with the time it appeared.
    func candidate() -> (DiscoveredPhone, ContinuousClock.Instant)? {
        lock.lock()
        defer { lock.unlock() }
        return phones.compactMap { phone in firstSeen[phone.name].map { (phone, $0) } }.min { $0.1 < $1.1 }
    }

    var denied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDenied
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
private final class ProgressReporter: @unchecked Sendable {
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
