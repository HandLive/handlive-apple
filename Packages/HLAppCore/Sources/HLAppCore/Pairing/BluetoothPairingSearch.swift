import Foundation
import HLTransport

/// Adapts `BtQrPairingSearch` (flow B) and `BtPinPairingSearch` (flow C, M7.2) to the uniform `PairingSearching`
/// interface `PairingController` holds, so the two Bluetooth searches can be raced against the LAN one the same
/// way regardless of which credential is active (`BluetoothFallbackPairingSearch`).
public struct BluetoothPairingSearch: PairingSearching {
    public let central: any BluetoothCentral
    /// PAIR-01 step 7: "Waits up to 20 s" before giving up on this scan (both Bluetooth searches' own default).
    public var overallTimeout: Duration = .seconds(20)

    public init(central: any BluetoothCentral) {
        self.central = central
    }

    public func run(identity: PairingIdentity, credential: PairingCredential, offerTimeout: Duration,
                    progress: @escaping @Sendable (PairingProgress) -> Void) async throws -> PairingResult {
        switch credential {
        case .qr(let secret, _):
            var search = BtQrPairingSearch(central: central)
            search.overallTimeout = overallTimeout
            return try await search.run(identity: identity, pairingSecret: secret, offerTimeout: offerTimeout)
        case .pin(let pin, let attemptsLeft):
            var search = BtPinPairingSearch(central: central)
            search.overallTimeout = overallTimeout
            return try await search.run(identity: identity, pin: pin, attemptsLeft: attemptsLeft, offerTimeout: offerTimeout)
        case .bluetoothPIN:
            // `PairingController` never holds this as its own credential: it is `BtPinPairingSearch`'s own internal
            // representation, built only after a Bluetooth PIN link has already secured (0.4.5 "PIN").
            preconditionFailure("BluetoothPairingSearch is never asked to search for a .bluetoothPIN credential")
        }
    }
}
