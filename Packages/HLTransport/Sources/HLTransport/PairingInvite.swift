import Foundation
import HLProtocol

/// The pairing QR code (PAIR-01 API 1): `handlive://pair?v=1&pk=<b64u>&ps=<b64u>&d=<name>[&rv=<b64u>]`.
public enum PairingInvite {
    /// The URI stays ≤ 300 characters so the code is version ≤ 10 and scans well from a Retina screen (logic 1).
    public static let maxURILength = 300
    /// `d` is string(64): at most 64 Unicode code points.
    public static let maxNameCodePoints = 64

    /// The QR URI; `name` should come from `fittedName` so it is not shortened here.
    public static func uri(clientDHPublicKey: Data, pairingSecret: Data, name: String, rendezvous: Data? = nil) -> String {
        var uri = "handlive://pair?v=1&pk=\(Base64Coding.encodeB64u(clientDHPublicKey))"
            + "&ps=\(Base64Coding.encodeB64u(pairingSecret))&d=\(percentEncoded(name))"
        if let rendezvous { uri += "&rv=\(Base64Coding.encodeB64u(rendezvous))" }
        return uri
    }

    /// The device name shortened, whole characters at a time, to 64 code points and to what keeps the URI within
    /// 300 characters. The same text goes into `pair/hello`, so the phone shows and stores one name.
    public static func fittedName(_ name: String, rendezvous: Bool = false) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // pk and ps are 43 characters each; rv adds "&rv=" and 22 characters.
        let fixedLength = "handlive://pair?v=1&pk=&ps=&d=".count + 43 + 43 + (rendezvous ? 26 : 0)
        var fitted = trimmed
        while fitted.unicodeScalars.count > maxNameCodePoints
            || fixedLength + percentEncoded(fitted).count > maxURILength {
            fitted.removeLast()
        }
        return fitted.trimmingCharacters(in: .whitespaces)
    }

    /// Percent-encodes every byte of the UTF-8 name except the RFC 3986 unreserved characters, so `+`, `&` and
    /// `=` survive any query parser ("MacBook của Lan" → `MacBook%20c%E1%BB%A7a%20Lan`).
    static func percentEncoded(_ text: String) -> String {
        var encoded = ""
        for byte in text.utf8 {
            let scalar = Unicode.Scalar(byte)
            if byte < 0x80, CharacterSet.unreservedURI.contains(scalar) {
                encoded.unicodeScalars.append(scalar)
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}

private extension CharacterSet {
    /// ALPHA / DIGIT / "-" / "." / "_" / "~" (RFC 3986 §2.3).
    static let unreservedURI = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
