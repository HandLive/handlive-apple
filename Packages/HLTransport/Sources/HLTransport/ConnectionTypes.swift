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
    /// `features.relay.enabled` of the phone's last capability; `false` → never reach it through the relay (SET-02
    /// API 1 logic 4). Unknown counts as on.
    public var relayEnabled: Bool
    /// Present while `relay_registered = 0`: the pair is registered with `POST /v1/pairs` before the relay is used
    /// (CONN-03 step 3, PAIR-01 E8).
    public var relayRegistration: RelayPairRegistration?

    public init(pair: PairContext, certificateSHA256: Data, lastHost: String? = nil, lastPort: UInt16? = nil,
                relayEnabled: Bool = true, relayRegistration: RelayPairRegistration? = nil) {
        self.pair = pair
        self.certificateSHA256 = certificateSHA256
        self.lastHost = lastHost
        self.lastPort = lastPort
        self.relayEnabled = relayEnabled
        self.relayRegistration = relayRegistration
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
    /// The relay's TLS chain carries none of the pinned keys: not used (CONN-03 E7).
    case relayUntrusted
    /// `410 DEVICE_REVOKED`: "This device was removed from the internet service"; the relay stays off until the user
    /// turns it on again (CONN-03 E3).
    case relayDeviceRemoved
    /// `429 RATE_LIMITED`: "Too many requests. Trying again in {duration}." with `nextRetry` (CONN-03 E6).
    case relayRateLimited
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
    /// Address of a LAN session (`last_host` / `last_port`); `nil` through the relay.
    public let host: String?
    public let port: UInt16?
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
    /// `POST /v1/pairs` succeeded: set `relay_registered = 1` (PAIR-01 API 8 logic 5).
    case relayPairRegistered(pairId: String)
    /// The relay no longer lists the pair although it was registered (the phone left the relay, C16): set
    /// `relay_registered = 0` and keep the pair for the LAN (PAIR-02 API 1 logic 3).
    case relayPairMissing(pairId: String)
    /// `410 DEVICE_REVOKED`: turn `relay.enabled` off until the user turns it on again (CONN-03 E3).
    case relayDeviceRevoked
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
    /// Waiting for the relay's first `presence` of the pair after connecting (CONN-03 step 6).
    public var presenceWait: Duration = .seconds(3)
    /// A `wake` push for the same reason goes out at most this often (CONN-03 E5, CONN-04 step 5a).
    public var wakeInterval: Duration = .seconds(300)
    /// An old relay session keeps delivering what was in flight this long after the LAN took over (CONN-02 step 7).
    public var upgradeGrace: Duration = .seconds(5)
    /// After a second 404 from `POST /v1/pairs` the pair waits this long before trying again (PAIR-01 API 8 logic 6).
    public var pairRegistrationPause: Duration = .seconds(86_400)
    /// `GET /v1/pairs` for the device screens at most this often (PAIR-02 step 4).
    public var pairCheckInterval: Duration = .seconds(60)
    public var session = SessionConfiguration()

    public init() {}
}
