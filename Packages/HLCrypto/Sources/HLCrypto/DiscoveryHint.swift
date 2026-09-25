import Foundation

/// mDNS hints (00-common-specs 0.4.1, C6): the TXT key `h` of the phone lists one hint per pair, so a client
/// finds its phone without the TXT record carrying a stable identifier.
///
/// `K_disc` = HKDF(`PRK`, info `"handlive/v1/discovery"`); hint = the first 8 hex characters of
/// HMAC-SHA256(`K_disc`, `"HLDISC1"` ‖ int64 BE `floor(now_ms / 3 600 000)`). Hints change every hour; the
/// client accepts the current and the previous hour to tolerate clock skew around the hour.
public enum DiscoveryHint {
    public static let info = "handlive/v1/discovery"
    public static let label = Data("HLDISC1".utf8)
    public static let hourMilliseconds: Int64 = 3_600_000

    /// `K_disc` of a pair.
    public static func key(prk: Data) throws -> Data {
        try Bytes.require(prk, count: 32)
        return HKDFSHA256.derive(ikm: prk, info: info, length: 32)
    }

    /// Hint of one hour index (`floor(now_ms / 3 600 000)`), 8 lowercase hex characters.
    public static func hint(discoveryKey: Data, hour: Int64) -> String {
        var message = label
        withUnsafeBytes(of: hour.bigEndian) { message.append(contentsOf: $0) }
        let mac = HMACSHA256.mac(key: discoveryKey, message: message)
        return mac.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Hints a client accepts at `nowMs`: the current hour first, then the previous one.
    public static func acceptedHints(prk: Data, nowMs: Int64) throws -> [String] {
        let discoveryKey = try key(prk: prk)
        let hour = nowMs >= 0 ? nowMs / hourMilliseconds : (nowMs - hourMilliseconds + 1) / hourMilliseconds
        return [hint(discoveryKey: discoveryKey, hour: hour), hint(discoveryKey: discoveryKey, hour: hour - 1)]
    }

    /// Whether a TXT `h` value (comma-separated hints) carries one of the accepted hints; case-insensitive.
    public static func matches(txtValue: String, accepted: [String]) -> Bool {
        let listed = Set(txtValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return accepted.contains { listed.contains($0.lowercased()) }
    }
}
