/// WebSocket close codes of the device-to-device channels (00-common-specs 0.8.3).
///
/// Codes outside this table (other RFC 6455 codes, codes from a newer peer) decode as `.other`
/// so a newer Android build never breaks the client (0.5.1 rule 6).
public enum CloseCode: Equatable, Hashable, Sendable {
    /// 1000 — normal closure (after `session/bye`, `pair/done`).
    case normal
    /// 4400 — `BAD_REQUEST` (also sent after `DECRYPT_FAILED`, CONN-02 E5).
    case badRequest
    /// 4401 — `AUTH_FAILED`: wrong `mac`, unknown pair or undecryptable first envelope.
    case authFailed
    /// 4403 — `PAIR_REVOKED`.
    case pairRevoked
    /// 4408 — handshake took longer than `HANDSHAKE_TIMEOUT`.
    case handshakeTimeout
    /// 4409 — the session was replaced by a newer connection of the same pair.
    case replaced
    /// 4410 — `REKEY_FAILED`: no `ack` within 10 s, error `ack` or bad data (CONN-02 E4).
    case rekeyFailed
    /// 4411 — `IDLE_TIMEOUT`: the session was silent for more than 45 s (CONN-02).
    case idleTimeout
    /// 4426 — `UNSUPPORTED_VERSION`.
    case unsupportedVersion
    /// 4429 — `RATE_LIMITED`: more than 16 connections before the handshake, or the IP is blocked for
    /// 5 minutes after wrong `mac` values (CONN-01 API 3, API 4).
    case rateLimited
    /// 4500 — `INTERNAL`.
    case `internal`
    /// Any other code; kept for logging.
    case other(UInt16)

    public init(rawValue: UInt16) {
        self = Self.documented.first { $0.rawValue == rawValue } ?? .other(rawValue)
    }

    public var rawValue: UInt16 {
        switch self {
        case .normal: 1000
        case .badRequest: 4400
        case .authFailed: 4401
        case .pairRevoked: 4403
        case .handshakeTimeout: 4408
        case .replaced: 4409
        case .rekeyFailed: 4410
        case .idleTimeout: 4411
        case .unsupportedVersion: 4426
        case .rateLimited: 4429
        case .internal: 4500
        case .other(let code): code
        }
    }

    /// Every code of the 0.8.3 table, in table order.
    public static let documented: [CloseCode] = [
        .normal, .badRequest, .authFailed, .pairRevoked, .handshakeTimeout, .replaced, .rekeyFailed,
        .idleTimeout, .unsupportedVersion, .rateLimited, .internal,
    ]

    /// Error code named by the 0.8.3 table, if any (4408, 4409 and 1000 carry none).
    public var errorCode: ErrorCode? {
        switch self {
        case .badRequest: .badRequest
        case .authFailed: .authFailed
        case .pairRevoked: .pairRevoked
        case .unsupportedVersion: .unsupportedVersion
        case .rateLimited: .rateLimited
        case .internal: .internal
        case .normal, .handshakeTimeout, .replaced, .rekeyFailed, .idleTimeout, .other: nil
        }
    }
}
