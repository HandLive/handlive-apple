/// Transport constants of 00-common-specs 0.4.1 and 0.10.
public enum TransportConstants {
    /// mDNS service type of the phone (0.4.1).
    public static let serviceType = "_handlive._tcp"
    /// WSS path of the control channel and of pairing (0.4.1).
    public static let controlPath = "/v1/ctl"
    public static let pairPath = "/v1/pair"
    /// `LAN_DISCOVERY_GRACE`: no candidate on the LAN after this → relay (P2) or backoff.
    public static let lanDiscoveryGrace: Duration = .seconds(10)
    /// `HANDSHAKE_TIMEOUT`.
    public static let handshakeTimeout: Duration = .seconds(5)
    /// `REQUEST_TIMEOUT`: wait for an `ack`.
    public static let requestTimeout: Duration = .seconds(10)
    /// `WS_PING_INTERVAL` / `PONG_TIMEOUT`.
    public static let pingInterval: Duration = .seconds(15)
    public static let pongTimeout: Duration = .seconds(10)
    /// `REKEY_AFTER`: 24 h or 10 000 envelopes in one direction.
    public static let rekeyAfterEnvelopes = 10_000
    public static let rekeyAfterAge: Duration = .seconds(24 * 3600)
    /// Old keys stay valid this long after a rekey for envelopes in flight (0.6.3 step 6).
    public static let rekeyOldKeyGrace: Duration = .seconds(30)
    /// `DEDUP_WINDOW`: 5 minutes / 1 000 ids.
    public static let dedupWindow: Duration = .seconds(300)
    public static let dedupCapacity = 1000
}
