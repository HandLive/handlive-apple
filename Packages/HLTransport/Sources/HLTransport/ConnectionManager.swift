import Foundation
import HLCrypto
import HLProtocol

/// Keeps the Mac or iPhone connected to its phone (CONN-01, CONN-02, CONN-03): discovery with the hourly hint and the
/// `last_host` fast path, pinned TLS, the session handshake, the relay when the LAN stays silent (with a `wake` push
/// while the phone is offline, and the upgrade back to the LAN), reconnection with `RECONNECT_BACKOFF`, network and
/// sleep events, and the 0.11 state machine. One consumer reads `events` (the app's coordinator).
public actor ConnectionManager {
    public nonisolated let events: AsyncStream<LinkEvent>
    let eventSink: AsyncStream<LinkEvent>.Continuation
    let discovery: any LANDiscovering
    let network: any NetworkMonitoring
    let connector: any ChannelConnecting
    let relay: RelayServices?
    let configuration: ConnectionConfiguration
    let signals = SignalQueue()

    var machine = ConnectionStateMachine()
    var backoff = ReconnectBackoff()
    var phone: PairedPhone?
    var localCapability: CapabilityData
    var networkPath: NetworkPathStatus?
    var discovered: [DiscoveredPhone] = []
    var discoveryState: DiscoveryState = .starting
    var issue: LinkIssue?
    var nextRetry: Date?
    /// Wait of the next `Backoff`; `nil` waits for a signal only (update required, pair removed).
    var pendingDelay: Duration?
    var sleeping = false
    var session: ControlSession?
    /// Identifies `session` in the signals of its watcher, so the end of an older session changes nothing.
    var sessionToken: UInt64 = 0
    var workers: [Task<Void, Never>] = []
    /// `relay.enabled` of this device (SET-02 field 21).
    var relayEnabled = true
    var relayLink: RelayLink?
    var lastWake: [RelayPushRequest.Reason: ContinuousClock.Instant] = [:]
    /// mDNS instances already tried for an upgrade from the relay; cleared when discovery results change.
    var upgradeTried: Set<String> = []

    public init(localCapability: CapabilityData, discovery: any LANDiscovering = BonjourDiscovery(),
                network: any NetworkMonitoring = PathMonitor(), connector: any ChannelConnecting = WebSocketConnector(),
                relay: RelayServices? = nil, configuration: ConnectionConfiguration = ConnectionConfiguration()) {
        self.localCapability = localCapability
        self.discovery = discovery
        self.network = network
        self.connector = connector
        self.relay = relay
        self.configuration = configuration
        (events, eventSink) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    // MARK: - Public API

    /// Starts browsing, watching the network and connecting whenever a phone is paired.
    public func start(phone: PairedPhone?, relayEnabled: Bool = true) {
        guard workers.isEmpty else { return }
        self.phone = phone
        self.relayEnabled = relayEnabled
        workers.append(Task { await self.watchNetwork() })
        workers.append(Task { await self.watchDiscovery() })
        workers.append(Task { await self.run() })
        publishStatus()
    }

    /// Stops everything: `session/bye {shutdown}` when connected (the user quits, CONN-02 step 8).
    public func stop() async {
        workers.forEach { $0.cancel() }
        workers.removeAll()
        await session?.close(bye: .shutdown)
        session = nil
        await closeRelay()
        eventSink.finish()
    }

    /// A pairing finished, the pair changed (relay registration, the phone's relay switch), or it was removed (`nil`).
    public func setPhone(_ newPhone: PairedPhone?) async {
        guard newPhone != phone else { return }
        if newPhone?.pair.pairId != phone?.pair.pairId, let current = session {
            session = nil
            await current.close(bye: newPhone == nil ? .revoked : .shutdown)
        }
        phone = newPhone
        if newPhone == nil {
            await closeRelay()
            apply(.unpaired)
        }
        signals.post(.phoneChanged)
    }

    /// "Reconnect Now": skip the backoff wait (CONN-01 field 5, CONN-02 field 4).
    public func reconnectNow() {
        issue = issue == .localNetworkDenied ? issue : nil
        signals.post(.reconnectNow)
    }

    /// `relay.enabled` changed (SET-02 field 21). Off: the session through the relay says `session/bye {shutdown}` and
    /// the relay connection closes; the LAN keeps working.
    public func setRelayEnabled(_ enabled: Bool) async {
        guard enabled != relayEnabled else { return }
        relayEnabled = enabled
        if enabled, issue == .relayDeviceRemoved || issue == .relayUntrusted { issue = nil }
        if !enabled { await leaveRelay() }
        signals.post(.relaySettingChanged)
    }

    /// Asks the relay to wake the phone (CONN-04 `wake`, e.g. `sms_send`) when it has no session; at most once per
    /// `wakeInterval` for the same reason.
    public func wakePhone(reason: RelayPushRequest.Reason) async {
        guard session == nil, relayUsable else { return }
        await sendWake(reason)
    }

    /// The Mac is about to sleep: say goodbye while there is time (CONN-02 E2).
    public func systemWillSleep() async {
        sleeping = true
        signals.post(.sleep)
        if let current = session {
            session = nil
            await current.close(bye: .shutdown)
        }
        await closeRelay()
    }

    /// The Mac woke up: run CONN-01 at once (CONN-02 E2).
    public func systemDidWake() {
        sleeping = false
        BenchLog.event("wake")
        signals.post(.wake)
    }

    /// Settings changed: the next `capability/hello` carries them, the current session gets `capability/update`.
    public func updateLocalCapability(_ capability: CapabilityData) async {
        localCapability = capability
        try? await session?.updateCapability(capability)
    }

    /// Current session, if connected.
    public var currentSession: ControlSession? { session }

    // MARK: - State

    /// Relay allowed here, configured, and not turned off by the phone.
    var relayUsable: Bool {
        relay != nil && relayEnabled && (phone?.relayEnabled ?? true) && issue != .relayUntrusted
    }

    /// Applies a 0.11 event, logs the bench `state` line and publishes the status.
    func apply(_ event: ConnectionEvent) {
        let from = machine.state
        guard machine.handle(event) else { return }
        var fields: KeyValuePairs<String, String> = ["from": from.benchName, "to": machine.state.benchName]
        if case .connected(let route) = machine.state {
            fields = ["from": from.benchName, "to": machine.state.benchName, "channel": route == .lan ? "lan" : "relay"]
        }
        BenchLog.event("state", fields)
        if machine.state != .backoff { nextRetry = nil }
        publishStatus()
    }

    func publishStatus() {
        eventSink.yield(.status(LinkStatus(state: machine.state, nextRetry: nextRetry, issue: issue)))
    }
}
