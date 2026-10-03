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

    // The search is a small state machine (match vs fallback, retry, rendezvous, give up); its branch count is
    // essential, not accidental, so the loop body is kept together rather than scattered across more helpers.
    // swiftlint:disable:next cyclomatic_complexity
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
            guard let (phone, seenSince) = board.nextAttempt(excluding: failedNames) else {
                if let result = try await Self.pairThroughRendezvous(credential, board: board, exchange: exchange,
                                                                     reporter: reporter) {
                    return result
                }
                try await waitForChange(board: board, failedNames: &failedNames, iterator: &iterator, reporter: reporter)
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

    /// No instance is ready to try right now: report the right status and wait — for the next browse change, or, when
    /// every visible instance has failed to connect, for `retryDelay` before clearing the blacklist so they are retried
    /// while they stay visible (PAIR-01 A2: the search keeps trying the window until it pairs or the caller's window
    /// closes).
    private func waitForChange(board: PhoneBoard, failedNames: inout Set<String>,
                               iterator: inout AsyncStream<Void>.AsyncIterator,
                               reporter: ProgressReporter) async throws {
        if board.denied {
            reporter.report(.localNetworkDenied)
        } else if let earliest = board.earliestSeen(), !board.wasReached,
                  earliest.duration(to: .now) >= unreachableAfter {
            reporter.report(.phoneUnreachable)
        } else if failedNames.isEmpty {
            reporter.report(.waitingForPhone)
        }
        if !board.visibleNames.isEmpty, board.visibleNames.isSubset(of: failedNames) {
            try await Task.sleep(for: retryDelay)
            failedNames.removeAll()
        } else {
            guard await iterator.next() != nil else { throw CancellationError() }
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
