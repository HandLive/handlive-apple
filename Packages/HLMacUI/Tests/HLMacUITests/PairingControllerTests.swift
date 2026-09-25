import Foundation
import HLAppCore
import HLCrypto
import HLProtocol
import HLTransport
import Testing
@testable import HLMacUI

/// A pairing search the test answers by hand; each run records its credential.
final class ScriptedSearch: PairingSearching, @unchecked Sendable {
    struct Run {
        let credential: PairingCredential
        let offerTimeout: Duration
        let progress: @Sendable (PairingProgress) -> Void
    }

    private let lock = NSLock()
    private var runs: [Run] = []
    private var pending: CheckedContinuation<PairingResult, Error>?

    var all: [Run] {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }

    func run(identity: PairingIdentity, credential: PairingCredential, offerTimeout: Duration,
             progress: @escaping @Sendable (PairingProgress) -> Void) async throws -> PairingResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                runs.append(Run(credential: credential, offerTimeout: offerTimeout, progress: progress))
                pending = continuation
                lock.unlock()
            }
        } onCancel: {
            self.answer(.failure(CancellationError()))
        }
    }

    /// Ends the current run.
    func answer(_ result: Result<PairingResult, Error>) {
        lock.lock()
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Polls `condition` on the main actor for up to two seconds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Pairing sheet controller (PAIR-01 on the Mac)")
@MainActor
struct PairingControllerTests {
    let model: AppModel
    let search = ScriptedSearch()

    init() {
        model = makeModel()
        model.launch()
    }

    func controller(lifetime: Duration = .seconds(120), paired: @escaping @MainActor (String) -> Void = { _ in })
        -> PairingController {
        PairingController(model: model, search: search, lifetime: lifetime, onPaired: paired)
    }

    static func result(name: String = "Pixel của Lan") -> PairingResult {
        PairingResult(pairId: UUID().uuidString.lowercased(), createdAt: 1_727_150_003_210,
                      phoneDeviceId: "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f", phoneName: name, phoneModel: "Pixel 8",
                      phoneOSVersion: "15", phoneSigningPublicKey: Data(repeating: 0x33, count: 32),
                      phoneDHPublicKey: Data(repeating: 0x44, count: 32), certificateSHA256: Data(repeating: 0x55, count: 32),
                      attestation: Data(repeating: 0x01, count: 127), signatureSelf: Data(repeating: 0x02, count: 64),
                      signaturePeer: Data(repeating: 0x03, count: 64), prk: Data(repeating: 0x99, count: 32))
    }

    @Test("Step 2: a QR code carrying this Mac's key and the search's secret, 120 s on the countdown")
    func showsQRCode() async throws {
        let pairing = controller()
        pairing.start()
        #expect(await eventually { search.all.count == 1 })
        let identity = try #require(model.pairingIdentity())
        guard case .qr(let secret) = try #require(search.all.first).credential else {
            Issue.record("expected a QR credential")
            return
        }
        #expect(pairing.qrURI == PairingInvite.uri(clientDHPublicKey: identity.dhPublicKey, pairingSecret: secret,
                                                   name: identity.name))
        #expect(pairing.secondsLeft == 120 && pairing.countdownText == "2:00")
        #expect(search.all.first?.offerTimeout == TransportConstants.requestTimeout)
        pairing.stop()
        #expect(pairing.qrURI.isEmpty)
    }

    @Test("A1–A2 and E7: a PIN with 3 attempts; a wrong one keeps the PIN; the third makes a new one")
    func pinAttempts() async throws {
        let pairing = controller()
        pairing.start()
        #expect(await eventually { search.all.count == 1 })
        pairing.usePIN()
        #expect(await eventually { search.all.count == 2 })
        let pin = pairing.pin
        #expect(pin.count == 6 && pairing.qrURI.isEmpty)
        #expect(search.all.last?.credential == .pin(pin, attemptsLeft: 3))
        search.answer(.failure(PairingFailure.pinInvalid(attemptsLeft: 2)))
        #expect(await eventually { search.all.count == 3 })
        #expect(search.all.last?.credential == .pin(pin, attemptsLeft: 2))
        search.answer(.failure(PairingFailure.pinInvalid(attemptsLeft: 0)))
        #expect(await eventually { search.all.count == 4 })
        #expect(search.all.last?.credential == .pin(pairing.pin, attemptsLeft: 3))
        pairing.stop()
    }

    @Test("E4: AUTH_FAILED shows the error in the sheet with a new code; E3 and local network denied too")
    func notices() async throws {
        let pairing = controller()
        pairing.start()
        #expect(await eventually { search.all.count == 1 })
        let firstURI = pairing.qrURI
        search.answer(.failure(PairingFailure.authFailed))
        #expect(await eventually { search.all.count == 2 })
        #expect(pairing.notice == .insecure && pairing.qrURI != firstURI)
        let run = try #require(search.all.last)
        run.progress(.verifying)
        #expect(await eventually { pairing.notice == nil && pairing.progress == .verifying })
        run.progress(.phoneUnreachable)
        #expect(await eventually { pairing.notice == .phoneNotFound })
        run.progress(.localNetworkDenied)
        #expect(await eventually { pairing.notice == .localNetworkDenied })
        #expect(pairing.notice?.text.isEmpty == false)
        pairing.stop()
    }

    @Test("Step 11–12: the pair is stored (record + PRK) before success is reported")
    func completes() async throws {
        var pairedName: String?
        let pairing = controller { pairedName = $0 }
        pairing.start()
        #expect(await eventually { search.all.count == 1 })
        let result = Self.result()
        search.answer(.success(result))
        #expect(await eventually { pairedName == "Pixel của Lan" })
        #expect(model.pairedDevice?.pairId == result.pairId)
        #expect(model.pairedDevice?.peerCertificateSHA256 == result.certificateSHA256)
        #expect(try model.secrets.load(account: SecretAccount.pairKey(pairId: result.pairId)) == result.prk)
        #expect(pairing.qrURI.isEmpty && pairing.pairedName == "Pixel của Lan")
    }

    @Test("At 0:00 a new code replaces the old one without an error; a QR code being verified finishes first")
    func refreshes() async throws {
        let pairing = controller(lifetime: .milliseconds(600))
        pairing.start()
        #expect(await eventually { search.all.count == 1 })
        let firstURI = pairing.qrURI
        #expect(await eventually { search.all.count == 2 })
        #expect(pairing.qrURI != firstURI && pairing.notice == nil)
        search.all.last?.progress(.verifying)
        try await Task.sleep(for: .milliseconds(900))
        #expect(search.all.count == 2 && pairing.secondsLeft == 0)
        pairing.stop()
    }

    @Test("Without keys the sheet shows the keys error instead of a code")
    func withoutKeys() {
        let pairing = PairingController(model: makeModel(), search: search) { _ in }
        pairing.start()
        #expect(pairing.notice == .keysMissing && pairing.qrURI.isEmpty && search.all.isEmpty)
    }

    @Test("PIN digits are grouped by three")
    func grouping() {
        #expect(PairingCardView.grouped("482915") == "482 915")
        #expect(PairingCardView.grouped("12") == "12")
    }
}
