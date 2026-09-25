import Foundation
import HLProtocol

/// The paired phone as the connection manager needs it: keys, pinned certificate and last known address.
public struct PairedPhone: Sendable, Equatable {
    public let pair: PairContext
    /// SHA-256 of the phone's TLS certificate, pinned at pairing (`peer_tls_sha256`).
    public let certificateSHA256: Data
    /// `last_host` / `last_port`: tried first, in parallel with mDNS (CONN-01 step 2).
    public var lastHost: String?
    public var lastPort: UInt16?

    public init(pair: PairContext, certificateSHA256: Data, lastHost: String? = nil, lastPort: UInt16? = nil) {
        self.pair = pair
        self.certificateSHA256 = certificateSHA256
        self.lastHost = lastHost
        self.lastPort = lastPort
    }
}

/// Something the user should know beyond the status (CONN-01 E3, E5, E8).
public enum LinkIssue: Sendable, Equatable {
    /// `AUTH_FAILED`: "Couldn't verify the phone"; retried after five minutes.
    case authFailed
    /// `UNSUPPORTED_VERSION`: the phone runs an older protocol → update HandLive on the phone.
    case updatePhoneApp
    /// The phone requires a newer protocol → update HandLive on this device.
    case updateThisApp
    /// Local network access denied: the phone cannot be found on the LAN.
    case localNetworkDenied
}

/// What the UI shows (StatusIndicator, menu bar menu, CONN-02 fields 1–4).
public struct LinkStatus: Sendable, Equatable {
    public var state: ConnectionState
    public var status: ConnectionStatus { ConnectionStatus(state) }
    /// Next automatic retry while in `Backoff` ("Retrying in 8 s").
    public var nextRetry: Date?
    public var issue: LinkIssue?

    public init(state: ConnectionState, nextRetry: Date? = nil, issue: LinkIssue? = nil) {
        self.state = state
        self.nextRetry = nextRetry
        self.issue = issue
    }
}

/// Where the connected session goes, to store as `last_host`, `last_port`, `features_json` (CONN-01 step 10).
public struct LinkDetails: Sendable, Equatable {
    public let route: ConnectionRoute
    public let host: String
    public let port: UInt16
    public let peerCapability: CapabilityData
}

/// The phone no longer has this pair: clean it up (PAIR-03 flow B, CONN-01 E4).
public enum PairRemoval: Sendable, Equatable {
    /// `pair/revoke` or `session/bye {reason: revoked}` from the phone.
    case revokedByPhone
    /// `session/error PAIR_UNKNOWN`.
    case unknownToPhone
    /// `session/error PAIR_REVOKED` or close 4403.
    case revoked
}

public enum LinkEvent: Sendable {
    case status(LinkStatus)
    /// A session reached `Connected`; features start (CONN-01 step 10).
    case connected(ControlSession, LinkDetails)
    /// Feature message of the current session.
    case message(IncomingEnvelope)
    case capabilityUpdated(CapabilityData)
    /// The current session ended.
    case disconnected
    case pairRemoved(PairRemoval)
}

/// Timings of the manager; defaults follow 0.10, tests shorten them.
public struct ConnectionConfiguration: Sendable {
    public var lanDiscoveryGrace = TransportConstants.lanDiscoveryGrace
    /// Opening TLS + WebSocket to one mDNS candidate.
    public var connectTimeout: Duration = .seconds(5)
    /// The `last_host` fast path gives up sooner: a stale address must not delay discovery.
    public var fastPathTimeout: Duration = .milliseconds(1500)
    /// Multiplies `RECONNECT_BACKOFF` and the AUTH_FAILED wait (tests use a small factor).
    public var delayScale = 1.0
    /// Relay client (CONN-03) arrives in Phase 2; until then the grace ends in `Backoff`.
    public var relayAvailable = false
    public var session = SessionConfiguration()

    public init() {}
}
