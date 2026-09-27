import Foundation

/// Where the relay lives and which keys its TLS chain must contain (0.4.3). `{RELAY_HOST}` is set at build time: the
/// app reads the Info.plist key `HLRelayHost` (build setting `HL_RELAY_HOST`); without it the relay is not used and the
/// apps work on the LAN only.
public struct RelayConfiguration: Sendable, Equatable {
    /// Info.plist keys: the host and an optional extra SPKI pin (Base64 of the SHA-256) — the project's backup key.
    public static let hostInfoKey = "HLRelayHost"
    public static let backupPinInfoKey = "HLRelayBackupPin"

    public let host: String
    public let port: Int
    /// SHA-256 of a SubjectPublicKeyInfo (DER) that must appear in the validated chain.
    public let spkiPins: Set<Data>

    public init(host: String, port: Int = 443, spkiPins: Set<Data> = RelayPins.letsEncryptRoots) {
        self.host = host
        self.port = port
        self.spkiPins = spkiPins
    }

    /// From the app's Info.plist; `nil` when no host is configured.
    public static func fromBundle(_ bundle: Bundle = .main) -> RelayConfiguration? {
        guard let host = (bundle.object(forInfoDictionaryKey: hostInfoKey) as? String)?
            .trimmingCharacters(in: .whitespaces), !host.isEmpty, !host.hasPrefix("$(")
        else { return nil }
        var pins = RelayPins.letsEncryptRoots
        if let backup = bundle.object(forInfoDictionaryKey: backupPinInfoKey) as? String,
           let pin = Data(base64Encoded: backup), pin.count == 32 {
            pins.insert(pin)
        }
        return RelayConfiguration(host: host, spkiPins: pins)
    }

    /// `https://{RELAY_HOST}/v1/<path>`.
    public func restURL(_ path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port == 443 ? nil : port
        components.path = "/v1/" + path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    /// `wss://{RELAY_HOST}/v1/relay`.
    public var relaySocketURL: URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = port == 443 ? nil : port
        components.path = "/v1/relay"
        return components.url
    }
}

/// SPKI pins of 0.4.3: ISRG Root X1 (RSA 4096) and ISRG Root X2 (ECDSA P-384), the roots of Let's Encrypt. Base64 of
/// SHA-256(SubjectPublicKeyInfo DER), as computed from the system root store.
public enum RelayPins {
    public static let isrgRootX1 = Data(base64Encoded: "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=")!
    public static let isrgRootX2 = Data(base64Encoded: "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=")!
    public static let letsEncryptRoots: Set<Data> = [isrgRootX1, isrgRootX2]
}
