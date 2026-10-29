import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLAppCore
@testable import HLTransport

/// `BluetoothFallbackPairingSearch` (M7.2-wire): races the LAN search against the Bluetooth one, shares a PIN's
/// attempt counter across both, and never spins when the Bluetooth side is `NullBluetoothCentral` (iOS, 0.4.5
/// "Roles": only the Mac is a Bluetooth central).
@Suite("Bluetooth fallback pairing search (M7.2-wire)")
struct BluetoothFallbackPairingSearchTests {
    static func identity() throws -> PairingIdentity {
        let seed = Ed25519.generateSeed()
        let dh = X25519.generatePrivateKey()
        let signing = try Ed25519.publicKey(seed: seed)
        return PairingIdentity(deviceId: try DeviceIdentity.deviceId(signingPublicKey: signing), name: "MacBook của Lan",
                               platform: .macos, model: "Mac15,3", signingSeed: seed, signingPublicKey: signing,
                               dhPrivateKey: dh, dhPublicKey: try X25519.publicKey(privateKey: dh))
    }

    static func result() -> PairingResult {
        PairingResult(pairId: UUID().uuidString.lowercased(), createdAt: 1_727_150_003_210,
                      phoneDeviceId: "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f", phoneName: "Pixel của Lan",
                      phoneModel: "Pixel 8", phoneOSVersion: "15", phoneSigningPublicKey: Data(repeating: 0x33, count: 32),
                      phoneDHPublicKey: Data(repeating: 0x44, count: 32), certificateSHA256: Data(repeating: 0x55, count: 32),
                      attestation: Data(repeating: 0x01, count: 127), signatureSelf: Data(repeating: 0x02, count: 64),
                      signaturePeer: Data(repeating: 0x03, count: 64), prk: Data(repeating: 0x99, count: 32))
    }

    @Test("Bluetooth secures a link and completes PAIR-01 while the LAN never finds a candidate: Bluetooth wins")
    func bluetoothWinsWhenLANHasNothing() async throws {
        let lan = ScriptedPairingSearching() // never answered: like PairingSearch.run with no candidate visible
        let bluetooth = ScriptedPairingSearching()
        let combined = BluetoothFallbackPairingSearch(lan: lan, bluetooth: bluetooth)
        let identity = try Self.identity()
        let expected = Self.result()
        let outcome = Task {
            try await combined.run(identity: identity, credential: .qr(secret: Data(count: 32)),
                                   offerTimeout: .seconds(1)) { _ in }
        }
        #expect(await bluetooth.awaitRun())
        await bluetooth.answer(.success(expected))
        #expect(try await outcome.value == expected)
        #expect(await lan.wasCancelled())
    }

    @Test("A wrong PIN over Bluetooth throws pinInvalid with the same attemptsLeft PairingController already handles")
    func wrongPinOverBluetoothSharesTheCounter() async throws {
        let lan = ScriptedPairingSearching()
        let bluetooth = ScriptedPairingSearching()
        let combined = BluetoothFallbackPairingSearch(lan: lan, bluetooth: bluetooth)
        let identity = try Self.identity()
        let outcome = Task {
            try await combined.run(identity: identity, credential: .pin("482917", attemptsLeft: 3),
                                   offerTimeout: .seconds(1)) { _ in }
        }
        #expect(await bluetooth.awaitRun())
        await bluetooth.answer(.failure(PairingFailure.pinInvalid(attemptsLeft: 2)))
        await #expect(throws: PairingFailure.pinInvalid(attemptsLeft: 2)) { try await outcome.value }
        #expect(await lan.wasCancelled())
    }

    @Test("A Bluetooth scan that only times out is retried, not treated as a final failure")
    func softBluetoothFailureIsRetried() async throws {
        let lan = ScriptedPairingSearching()
        let bluetooth = ScriptedPairingSearching()
        let combined = BluetoothFallbackPairingSearch(lan: lan, bluetooth: bluetooth)
        let identity = try Self.identity()
        let expected = Self.result()
        let outcome = Task {
            try await combined.run(identity: identity, credential: .qr(secret: Data(count: 32)),
                                   offerTimeout: .seconds(1)) { _ in }
        }
        #expect(await bluetooth.awaitRun())
        await bluetooth.answer(.failure(BtQrPairingSearchError.timedOut))
        #expect(await bluetooth.awaitRun())
        await bluetooth.answer(.success(expected))
        #expect(try await outcome.value == expected)
    }

    @Test("iOS's NullBluetoothCentral: the search never spins, it just runs the LAN side")
    func nullCentralRunsLANOnly() async throws {
        let lan = ScriptedPairingSearching()
        let combined = BluetoothFallbackPairingSearch(lan: lan,
                                                       bluetooth: BluetoothPairingSearch(central: NullBluetoothCentral()))
        let identity = try Self.identity()
        let expected = Self.result()
        let outcome = Task {
            try await combined.run(identity: identity, credential: .qr(secret: Data(count: 32)),
                                   offerTimeout: .seconds(1)) { _ in }
        }
        #expect(await lan.awaitRun())
        await lan.answer(.success(expected))
        #expect(try await outcome.value == expected)
    }

    @Test("The LAN finishing first still reports a wrong-PIN failure the same way")
    func lanFailureStillPropagates() async throws {
        let lan = ScriptedPairingSearching()
        let bluetooth = ScriptedPairingSearching()
        let combined = BluetoothFallbackPairingSearch(lan: lan, bluetooth: bluetooth)
        let identity = try Self.identity()
        let outcome = Task {
            try await combined.run(identity: identity, credential: .pin("482917", attemptsLeft: 1),
                                   offerTimeout: .seconds(1)) { _ in }
        }
        #expect(await lan.awaitRun())
        await lan.answer(.failure(PairingFailure.pinInvalid(attemptsLeft: 0)))
        await #expect(throws: PairingFailure.pinInvalid(attemptsLeft: 0)) { try await outcome.value }
        #expect(await bluetooth.wasCancelled())
    }
}

/// A `PairingSearching` the test answers by hand, parallel to `HLMacUITests.ScriptedSearch` (not reusable here:
/// that one is private to `HLMacUI`'s test target).
final actor ScriptedPairingSearching: PairingSearching {
    private var pending: CheckedContinuation<PairingResult, Error>?
    private var cancelled = false
    private var runStarted: CheckedContinuation<Void, Never>?

    nonisolated func run(identity: PairingIdentity, credential: PairingCredential, offerTimeout: Duration,
                         progress: @escaping @Sendable (PairingProgress) -> Void) async throws -> PairingResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await self.begin(continuation) }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func begin(_ continuation: CheckedContinuation<PairingResult, Error>) {
        pending = continuation
        runStarted?.resume()
        runStarted = nil
    }

    private func cancel() {
        cancelled = true
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }

    /// Waits until `run` has been called (and not yet answered) — avoids a race between the test calling `answer`
    /// and the combinator actually starting this fake's `run`.
    func awaitRun() async -> Bool {
        if pending != nil { return true }
        await withCheckedContinuation { runStarted = $0 }
        return pending != nil
    }

    func answer(_ result: Result<PairingResult, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }

    func wasCancelled() async -> Bool {
        // The combinator's `group.cancelAll()` races with this check; give the cancellation handler a moment.
        for _ in 0..<50 where !cancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cancelled
    }
}
