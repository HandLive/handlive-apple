/// Client connection state machine of the Mac/iOS apps (00-common-specs 0.11). Pure logic, no
/// networking: the connection layer reports `ConnectionEvent`s, the machine decides the next state.
public enum ConnectionRoute: Equatable, Hashable, Sendable {
    case lan
    case relay
    /// Mac only (0.4.5); iOS has no Bluetooth route (0.11).
    case bluetooth

    /// Pre-authentication rule by route (0.11 AC8): true for `lan` (and `usb`, which this type folds into `lan` —
    /// 0.11 "Routes and priority"). Before the session handshake has authenticated the phone, a route where this
    /// is `false` must never act on `PAIR_UNKNOWN`/`PAIR_REVOKED` (CONN-01 E4, CONN-03 E9, CONN-05 E5): anyone on
    /// that path could forge the error.
    public var phoneAuthenticatedByTLS: Bool {
        switch self {
        case .lan: true
        case .relay, .bluetooth: false
        }
    }
}

/// Why the client is idle. Only `needsRepair` asks the user to act ("Needs re-pairing").
public enum IdleReason: Equatable, Hashable, Sendable {
    /// No active pair: first run, or the last pair was removed.
    case notPaired
    /// The Mac has no network path (CONN-02 E1); wait for the path monitor.
    case noNetwork
    /// Every instance of the pair failed the certificate pin: the phone regenerated its TLS key
    /// (0.6.1, CONN-01 E2). Retrying cannot help until the user pairs again.
    case needsRepair
}

public enum ConnectionState: Equatable, Hashable, Sendable {
    case idle(IdleReason)
    case discovering
    case connectingLAN
    /// Opening the L2CAP channel and running the link-security handshake over Bluetooth (0.4.5, CONN-05).
    case connectingBT
    case connectingRelay
    case waitingPeer
    case handshaking(ConnectionRoute)
    case connected(ConnectionRoute)
    case backoff

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

/// Events named after the edge labels of the 0.11 diagram.
public enum ConnectionEvent: Equatable, Hashable, Sendable {
    /// At least one pair and a network path.
    case pairedAndNetworkAvailable
    /// An mDNS instance (or the known `last_host`) carries a matching hint.
    case lanInstanceFound
    /// TLS succeeded and the certificate matches the pin.
    case tlsPinVerified
    /// `TLS_PIN_MISMATCH` on one instance: drop it, keep discovering.
    case tlsPinMismatch
    /// Every instance of the pair failed the pin ("Needs re-pairing").
    case allInstancesPinMismatch
    /// Network or TLS error that is not a pin mismatch.
    case lanConnectFailed
    /// Valid `welcome` and capability exchanged.
    case handshakeSucceeded
    /// Handshake error, `session/error`, client-side `HANDSHAKE_TIMEOUT` or close 4408.
    case handshakeFailed
    /// `LAN_DISCOVERY_GRACE` elapsed; relay only when `relay.enabled`.
    case lanDiscoveryGraceElapsed(relayEnabled: Bool)
    /// A Bluetooth advertisement with a matching hint, no LAN candidate (0.11, CONN-05). Connects at once: unlike
    /// the relay, Bluetooth does not wait for `LAN_DISCOVERY_GRACE`.
    case bluetoothInstanceFound
    /// The link-security handshake over Bluetooth succeeded (0.4.5); next is the session handshake.
    case linkSecurityVerified
    /// Channel not opened, `reject`, `BT_PREAUTH_TIMEOUT` or the link-security handshake failed (CONN-05 E3, E4).
    case bluetoothConnectFailed
    /// Bluetooth pairing (PAIR-01 flow B) ended with `pair/done`: the link is kept, straight into the session
    /// handshake (0.11 "Idle --> Handshaking").
    case bluetoothPairingLinkKept
    /// Relay reached, peer offline.
    case relayConnectedPeerOffline
    /// Relay unreachable, or 401/404 after registering again.
    case relayFailed
    /// Relay connection lost while waiting for the peer.
    case relayConnectionLost
    /// `presence` online.
    case peerOnline
    /// Over the relay, the phone left: relay `error NOT_CONNECTED` or its channel closed while the relay stays up
    /// (CONN-03 E8).
    case peerOffline
    case connectionLost
    /// Session goes through the relay and the phone shows up on the LAN (upgrade); while waiting for the phone on the
    /// relay, the phone shows up on the LAN.
    case lanAvailable
    case backoffElapsed
    case networkChanged
    /// No network path at all (CONN-02 E1).
    case networkLost
    /// The last pair was removed.
    case unpaired
}

public struct ConnectionStateMachine: Sendable {
    public private(set) var state: ConnectionState

    public init(state: ConnectionState = .idle(.notPaired)) {
        self.state = state
    }

    /// Applies an event; returns `true` when the state changed. Events without an edge are ignored.
    @discardableResult
    public mutating func handle(_ event: ConnectionEvent) -> Bool {
        guard let next = Self.transition(from: state, on: event), next != state else { return false }
        state = next
        return true
    }

    // swiftlint:disable:next cyclomatic_complexity
    public static func transition(from state: ConnectionState, on event: ConnectionEvent) -> ConnectionState? {
        switch (state, event) {
        case (_, .unpaired): return .idle(.notPaired)
        case (.idle, .networkLost): return nil
        // A session over Bluetooth is not a LAN or relay session: losing the network does not touch it (0.11
        // "Start and loss"; CONN-02 E1, CONN-05 E11). Must come before the catch-all below.
        case (.connected(.bluetooth), .networkLost): return nil
        case (_, .networkLost): return .idle(.noNetwork)
        case (.idle, .pairedAndNetworkAvailable): return .discovering
        case (.discovering, .lanInstanceFound): return .connectingLAN
        case (.discovering, .lanDiscoveryGraceElapsed(relayEnabled: true)): return .connectingRelay
        case (.discovering, .lanDiscoveryGraceElapsed(relayEnabled: false)): return .backoff
        // A Bluetooth candidate connects at once, from Discovering or straight out of Idle (0.11 "Routes and
        // priority": no LAN_DISCOVERY_GRACE wait, unlike the relay).
        case (.discovering, .bluetoothInstanceFound), (.idle, .bluetoothInstanceFound): return .connectingBT
        case (.connectingLAN, .tlsPinVerified): return .handshaking(.lan)
        case (.connectingLAN, .tlsPinMismatch): return .discovering
        case (.connectingLAN, .allInstancesPinMismatch): return .idle(.needsRepair)
        case (.connectingLAN, .lanConnectFailed): return .backoff
        case (.connectingBT, .linkSecurityVerified): return .handshaking(.bluetooth)
        case (.connectingBT, .bluetoothConnectFailed): return .backoff
        // Bluetooth pairing (PAIR-01 flow B) ends with the link kept: straight to the session handshake, no
        // separate ConnectingBT step (0.11 "Idle --> Handshaking").
        case (.idle, .bluetoothPairingLinkKept): return .handshaking(.bluetooth)
        case (.connectingRelay, .relayConnectedPeerOffline): return .waitingPeer
        case (.connectingRelay, .relayFailed): return .backoff
        case (.connectingRelay, .peerOnline), (.waitingPeer, .peerOnline): return .handshaking(.relay)
        case (.waitingPeer, .relayConnectionLost): return .backoff
        case (.waitingPeer, .lanAvailable): return .discovering
        case (.connected(.relay), .peerOffline), (.handshaking(.relay), .peerOffline): return .waitingPeer
        case (.handshaking(let route), .handshakeSucceeded): return .connected(route)
        case (.handshaking, .handshakeFailed): return .backoff
        case (.connected, .connectionLost): return .backoff
        // Upgrade to the LAN from either non-LAN route (0.11 "Connected --> ConnectingLAN: on the relay or
        // Bluetooth and the LAN is found").
        case (.connected(.relay), .lanAvailable), (.connected(.bluetooth), .lanAvailable): return .connectingLAN
        case (.backoff, .backoffElapsed), (.backoff, .networkChanged): return .discovering
        default: return nil
        }
    }
}

/// Status shown to the user (PAIR-02 field 4, CONN-01 field 1, 0.11). Text comes from the string catalog
/// in the UI layer; the transport only says which status applies.
public enum ConnectionStatus: Equatable, Hashable, Sendable {
    case notPaired
    case disconnected
    case connecting
    case phoneOffline
    case connected(ConnectionRoute)
    case needsRepair

    public init(_ state: ConnectionState) {
        switch state {
        case .idle(.notPaired): self = .notPaired
        case .idle(.needsRepair): self = .needsRepair
        case .idle(.noNetwork), .backoff: self = .disconnected
        case .discovering, .connectingLAN, .connectingBT, .connectingRelay, .handshaking: self = .connecting
        case .waitingPeer: self = .phoneOffline
        case .connected(let route): self = .connected(route)
        }
    }
}
