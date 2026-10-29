import Foundation
import HLTransport

/// Races the LAN search against a Bluetooth one so the Mac can pair with no shared network at all (M7.2,
/// "chạy BtQrPairingSearch song song... hoặc làm phương án dự phòng cho rendezvous LAN"): whichever side secures a
/// link and finishes PAIR-01 first wins. 0.4.5 "Pairing mode" says the LAN candidate wins when both are visible;
/// in practice the LAN is almost always faster to discover and connect once reachable, so racing already gives it
/// that edge without a separate precedence check.
///
/// A PIN's `attemptsLeft` is shared across both transports (0.4.5 "PIN", C3): since both sides start from the same
/// `credential`, a wrong PIN on *either* one throws the same `PairingFailure.pinInvalid(attemptsLeft:)`
/// `PairingController` already knows how to act on, with no extra bookkeeping needed here.
public struct BluetoothFallbackPairingSearch: PairingSearching {
    public let lan: any PairingSearching
    public let bluetooth: any PairingSearching

    public init(lan: any PairingSearching, bluetooth: any PairingSearching) {
        self.lan = lan
        self.bluetooth = bluetooth
    }

    public func run(identity: PairingIdentity, credential: PairingCredential, offerTimeout: Duration,
                    progress: @escaping @Sendable (PairingProgress) -> Void) async throws -> PairingResult {
        // iOS never has a real central (`ConnectionManager.defaultBluetoothCentral()` is `NullBluetoothCentral`
        // there, 0.4.5 "Roles": only the Mac scans) — its `events()` stream ends at once, so racing it would mean
        // `BtQrPairingSearch`/`BtPinPairingSearch` throwing `timedOut` immediately and `runBluetoothUntilDone`
        // below retrying in a tight loop for as long as the sheet stays open. Recognize that one case and skip
        // straight to the LAN search instead of spinning.
        if let adapter = bluetooth as? BluetoothPairingSearch, adapter.central is NullBluetoothCentral {
            return try await lan.run(identity: identity, credential: credential, offerTimeout: offerTimeout,
                                     progress: progress)
        }
        return try await withThrowingTaskGroup(of: PairingResult.self) { group in
            group.addTask {
                try await lan.run(identity: identity, credential: credential, offerTimeout: offerTimeout, progress: progress)
            }
            group.addTask {
                try await Self.runBluetoothUntilDone(bluetooth, identity: identity, credential: credential,
                                                     offerTimeout: offerTimeout)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// Any failure that is not a definite `PairingFailure` — the Bluetooth search's own "no candidate reached
    /// `cpace1`/completed the handshake within its timeout" — is not a reason to give up: Bluetooth is scanned
    /// again, for as long as the LAN side keeps running (which, like `PairingSearch.run`, never gives up on its
    /// own either). A `PairingFailure` (wrong PIN, `AUTH_FAILED`) or cancellation ends the race at once.
    private static func runBluetoothUntilDone(_ bluetooth: any PairingSearching, identity: PairingIdentity,
                                              credential: PairingCredential,
                                              offerTimeout: Duration) async throws -> PairingResult {
        while true {
            try Task.checkCancellation()
            do {
                return try await bluetooth.run(identity: identity, credential: credential, offerTimeout: offerTimeout) { _ in }
            } catch let failure as PairingFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
    }
}
