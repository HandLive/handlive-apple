import CryptoKit
import Foundation

/// One `HLWEB key=value …` line, the same shape as the Android spike's. Full addresses and titles are never written:
/// only the host, a salted hash of the full address and the title's length.
public enum LogLine {
    public static let tag = "HLWEB"

    public static func format(_ fields: KeyValuePairs<String, Any?>) -> String {
        var line = tag
        for (key, value) in fields {
            guard let value else { continue }
            let text = String(describing: value).map { $0.isWhitespace || $0 == "=" ? "_" : $0 }
            line += " \(key)=\(String(text))"
        }
        return line
    }

    /// First 12 hex digits of SHA-256(salt + address); the salt is random per install.
    public static func hash(_ url: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + url).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
