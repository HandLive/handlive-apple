import Foundation

/// A PIN's failed-attempt budget (PAIR-01 C3, E7): shared by reference between the LAN exchange
/// (`PairingExchange`) and the Bluetooth search (`BtPinPairingSearch`) racing for the same code
/// (`BluetoothFallbackPairingSearch`). A wrong PIN on either transport spends from this one actor, so attempts
/// already spent by the side `cancelAll()` cancels are never lost (Trang's finding, #3932): an attacker split
/// between Wi-Fi and Bluetooth still cannot try more guesses than the PIN allows.
public actor PinAttemptCounter {
    public private(set) var left: Int

    public init(left: Int) {
        self.left = left
    }

    /// Spends one attempt and returns what is left.
    public func spend() -> Int {
        left = max(left - 1, 0)
        return left
    }
}
