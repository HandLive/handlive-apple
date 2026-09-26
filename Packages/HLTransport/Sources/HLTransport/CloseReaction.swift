import HLProtocol

/// What the client does after the phone closes `/v1/ctl` with a given code (0.8.3, CONN-01 E3–E6,
/// CONN-02 E4, E5, E7). A `session/error` received before the close takes precedence: its code says more
/// (for example `PAIR_UNKNOWN` travels with close code 4401).
public enum CloseReaction: Equatable, Hashable, Sendable {
    /// Retry on the `RECONNECT_BACKOFF` schedule.
    case backoff
    /// `AUTH_FAILED`: no automatic retry before `ReconnectBackoff.authFailedDelay` (CONN-01 E3).
    case backoffAfterAuthFailure
    /// `PAIR_REVOKED`: clean the pair up as in PAIR-03 flow B and ask to pair again (CONN-01 E4).
    case removePair
    /// `UNSUPPORTED_VERSION`: stop retrying and ask to update the older app (CONN-01 E5).
    case updateRequired
    /// Replaced by a newer connection of this client: the old session never reconnects (CONN-02 E7).
    case none
}

extension CloseCode {
    public var clientReaction: CloseReaction {
        switch self {
        case .authFailed: .backoffAfterAuthFailure
        case .pairRevoked: .removePair
        case .unsupportedVersion: .updateRequired
        case .replaced: .none
        // 4410 REKEY_FAILED and 4411 IDLE_TIMEOUT: a fresh handshake makes new keys (CONN-02 E4);
        // 4400 after DECRYPT_FAILED (E5), 4408 (E6), 4429 RATE_LIMITED, 4500, 1000 and unknown codes: back off.
        case .normal, .badRequest, .handshakeTimeout, .rekeyFailed, .idleTimeout, .rateLimited, .internal, .other:
            .backoff
        }
    }
}

extension ErrorCode {
    /// Reaction to `session/error` (CONN-01 API 6).
    public var sessionErrorReaction: CloseReaction {
        switch self {
        case .authFailed: .backoffAfterAuthFailure
        case .pairUnknown, .pairRevoked: .removePair
        case .unsupportedVersion: .updateRequired
        default: .backoff
        }
    }
}
