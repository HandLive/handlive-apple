import Foundation

/// Secrets the Mac/iPhone shows to start pairing (PAIR-01 step 2, A2). Both come from the system CSPRNG, live at
/// most 120 s and are never logged.
public enum PairingCodes {
    /// Lifetime of one QR code or PIN before a new one replaces it (`PAIRING_WINDOW`, PAIR-01 field 2).
    public static let lifetime: Duration = .seconds(120)

    /// `pairing_secret`: 256 random bits, carried only by the QR code (`ps`).
    public static func newPairingSecret() -> Data {
        Bytes.random(32)
    }

    /// A 6-digit PIN, uniformly distributed over 000000–999999 (`random(in:)` rejects the biased range).
    public static func newPIN() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt32.random(in: 0..<1_000_000, using: &generator)
        return String(format: "%06u", value)
    }

    /// `nonce_c` of `pair/hello`: 32 random bytes.
    public static func newNonce() -> Data {
        Bytes.random(32)
    }
}
