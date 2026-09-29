import Foundation

/// A page address ready to send (W2: `http`/`https` only, at most 8 KiB of UTF-8, host in ASCII).
public struct NormalizedURL: Equatable, Sendable {
    public let url: String
    /// Lower-case ASCII host (punycode for IDNs): the only part of the address the spike logs.
    public let host: String
}

/// Turns what a browser reports for its active tab into an address (WEB-03): only `http` and `https`, no user info,
/// internationalized hosts converted to punycode. `about:blank`, `favorites://`, `chrome://newtab`, `file:` and
/// similar are rejected: they are not pages the other device can open.
public enum URLNormalizer {
    public static let maxURLBytes = 8 * 1024

    public static func normalize(_ raw: String?) -> NormalizedURL? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains(where: \.isWhitespace),
              let schemeEnd = text.range(of: "://")
        else { return nil }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let rest = text[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        let tail = rest[authorityEnd...]
        guard !authority.isEmpty, !authority.contains("@"), !authority.hasPrefix("["),
              let (rawHost, port) = splitPort(authority),
              let host = asciiHost(rawHost)
        else { return nil }
        let url = "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "") + tail
        guard url.utf8.count <= maxURLBytes, URL(string: url) != nil || containsOnlyUnicodeInPath(url) else {
            return nil
        }
        return NormalizedURL(url: url, host: host)
    }

    private static func splitPort(_ authority: Substring) -> (Substring, Int?)? {
        guard let colon = authority.lastIndex(of: ":") else { return (authority, nil) }
        guard let port = Int(authority[authority.index(after: colon)...]), (1...65_535).contains(port) else {
            return nil
        }
        return (authority[..<colon], port)
    }

    /// `URL(string:)` on macOS 13 rejects raw non-ASCII in the path; browsers normally report it percent-encoded.
    private static func containsOnlyUnicodeInPath(_ url: String) -> Bool {
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed))
        return encoded.flatMap { URL(string: $0) } != nil
    }

    static func asciiHost(_ raw: Substring) -> String? {
        var host = raw.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var ascii: [String] = []
        for label in labels {
            guard !label.isEmpty else { return nil }
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                ascii.append(label)
            } else {
                guard let encoded = Punycode.encode(label) else { return nil }
                ascii.append("xn--" + encoded)
            }
        }
        guard ascii.allSatisfy(isValidLabel) else { return nil }
        if ascii.count == 4, ascii.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return ascii.allSatisfy { (Int($0) ?? 256) <= 255 } ? ascii.joined(separator: ".") : nil
        }
        guard ascii.count >= 2 || ascii == ["localhost"], !(ascii.last ?? "").allSatisfy(\.isNumber) else {
            return nil
        }
        return ascii.joined(separator: ".")
    }

    private static func isValidLabel(_ label: String) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }
}
