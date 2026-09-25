import CryptoKit
import Foundation

/// HMAC-SHA256 và SHA-256.
public enum HMACSHA256 {
    public static func mac(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// So sánh hằng thời gian (CryptoKit `isValidAuthenticationCode`).
    public static func verify(_ mac: Data, key: Data, message: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: SymmetricKey(data: key))
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Constant-time equality for MACs and `prk_check` values (PAIR-01: HMAC comparison is constant-time).
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
