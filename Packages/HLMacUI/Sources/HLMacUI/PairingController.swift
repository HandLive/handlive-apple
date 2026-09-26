import Foundation
import HLCrypto
import HLLocalization
import HLTransport

/// The showing side of PAIR-01 on the Mac: a QR code (or a PIN, A1–A2) that lives 120 s and is then replaced without
/// an error, the search for the phone's pairing window, the PIN attempts (E7) and the errors shown inside the sheet
/// (E3, E4). Secrets live only here, in memory, and are dropped on every new code and on `stop()`.
@MainActor
public final class PairingController: ObservableObject {
    public enum Mode: Equatable, Sendable {
        case qr, pin
    }

    /// Text shown inside the sheet, never as an alert (01-thiet-lap-ban-dau.md, Pairing).
    public enum Notice: Equatable, Sendable {
        /// E4: "Pairing isn't secure — try again", with a new code.
        case insecure
        /// E3: the phone's window was seen but could not be reached.
        case phoneNotFound
        /// SET-03 E4: no local network access, with "Open System Settings".
        case localNetworkDenied
        /// The pair could not be stored (field 10: a failure without its own text).
        case saveFailed
        /// The keys of this Mac are not loaded (SET-03 E1).
        case keysMissing

        public var text: String {
            switch self {
            case .insecure: L10n.Error.pairingAuthFailed
            case .phoneNotFound: L10n.Pairing.phoneNotFound
            case .localNetworkDenied: L10n.Setup.localNetworkDeniedMac
            case .saveFailed: L10n.Error.pairingFailed
            case .keysMissing: L10n.Setup.keysFailed
            }
        }
    }

    public static let pinAttempts = 3

    @Published public private(set) var mode = Mode.qr
    /// The QR URI of the current code (empty in PIN mode).
    @Published public private(set) var qrURI = ""
    /// The current PIN, six digits (empty in QR mode).
    @Published public private(set) var pin = ""
    @Published public private(set) var secondsLeft = 0
    @Published public private(set) var progress = PairingProgress.waitingForPhone
    @Published public private(set) var notice: Notice?
    @Published public private(set) var pairedName: String?

    public let deviceName: String
    private let model: AppModel
    private let search: any PairingSearching
    private let lifetime: Duration
    private let onPaired: @MainActor (String) -> Void
    private var identity: PairingIdentity?
    private var credential: PairingCredential?
    private var expiresAt = ContinuousClock.now
    private var searchTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// Results of a search started for an older code are ignored.
    private var generation = 0

    public init(model: AppModel,
                search: any PairingSearching = PairingSearch(discovery: BonjourDiscovery(), connector: WebSocketConnector()),
                lifetime: Duration = PairingCodes.lifetime, onPaired: @escaping @MainActor (String) -> Void) {
        self.model = model
        self.search = search
        self.lifetime = lifetime
        self.onPaired = onPaired
        identity = model.pairingIdentity()
        deviceName = identity?.name ?? model.device.name
    }

    /// PAIR-01 step 2: the first code, the search and the countdown.
    public func start() {
        guard ticker == nil, identity != nil else {
            if identity == nil { notice = .keysMissing }
            return
        }
        newCode()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    /// "Can't Scan? Use a PIN" (A1): a PIN replaces the QR code.
    public func usePIN() {
        guard mode == .qr else { return }
        mode = .pin
        notice = nil
        newCode()
    }

    /// Cancel, the sheet closing, or a pair made: stop searching and forget the secret.
    public func stop() {
        ticker?.cancel()
        ticker = nil
        searchTask?.cancel()
        searchTask = nil
        generation += 1
        credential = nil
        qrURI = ""
        pin = ""
    }

    /// "1:42" for `pairing.qr_code_changes_in`.
    public var countdownText: String {
        Duration.seconds(secondsLeft).formatted(.time(pattern: .minuteSecond))
    }

    private func tick() {
        let remaining = ContinuousClock.now.duration(to: expiresAt).components
        secondsLeft = max(0, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
        guard secondsLeft == 0, credential != nil else { return }
        // A QR code the phone already scanned finishes first (the exchange takes about a second); a PIN is replaced
        // even while the phone waits for it to be typed.
        if mode == .qr, progress == .verifying { return }
        newCode()
    }

    /// A new secret or PIN (the old one is dropped) and a new search (steps 2, A2; E7 after 3 wrong PINs).
    private func newCode() {
        guard let identity else { return }
        switch mode {
        case .qr:
            let secret = PairingCodes.newPairingSecret()
            credential = .qr(secret: secret)
            qrURI = PairingInvite.uri(clientDHPublicKey: identity.dhPublicKey, pairingSecret: secret, name: identity.name)
            pin = ""
        case .pin:
            pin = PairingCodes.newPIN()
            credential = .pin(pin, attemptsLeft: Self.pinAttempts)
            qrURI = ""
        }
        expiresAt = .now.advanced(by: lifetime)
        secondsLeft = Int(lifetime.components.seconds)
        startSearch()
    }

    private func startSearch() {
        guard let identity, let credential else { return }
        searchTask?.cancel()
        generation += 1
        let generation = generation
        progress = .waitingForPhone
        // With a PIN the phone answers once the user typed it: wait up to the PIN's lifetime.
        let offerTimeout = mode == .qr ? TransportConstants.requestTimeout : lifetime
        searchTask = Task { [search, weak self] in
            do {
                let result = try await search.run(identity: identity, credential: credential,
                                                  offerTimeout: offerTimeout) { progress in
                    Task { @MainActor in self?.update(progress, generation: generation) }
                }
                self?.finish(result, generation: generation)
            } catch {
                self?.failed(error, generation: generation)
            }
        }
    }

    private func update(_ value: PairingProgress, generation: Int) {
        guard generation == self.generation else { return }
        progress = value
        switch value {
        case .phoneUnreachable: notice = .phoneNotFound
        case .localNetworkDenied: notice = .localNetworkDenied
        case .verifying: if notice != nil, notice != .saveFailed, notice != .keysMissing { notice = nil }
        case .waitingForPhone: if notice == .localNetworkDenied { notice = nil }
        case .connecting: break
        }
    }

    private func finish(_ result: PairingResult, generation: Int) {
        guard generation == self.generation else { return }
        do {
            try model.completePairing(result)
        } catch {
            notice = .saveFailed
            newCode()
            return
        }
        stop()
        pairedName = result.phoneName
        onPaired(result.phoneName)
    }

    private func failed(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        switch error {
        case PairingFailure.authFailed:
            notice = .insecure
            newCode()
        case PairingFailure.pinInvalid(let attemptsLeft) where attemptsLeft > 0:
            credential = .pin(pin, attemptsLeft: attemptsLeft)
            startSearch()
        case PairingFailure.pinInvalid:
            newCode() // E7: a new PIN after the third wrong one
        case is CancellationError:
            break
        default:
            startSearch()
        }
    }
}
