import Foundation
import HLCrypto
import HLProtocol

/// Keeps the Mac connected to its phone (CONN-01, CONN-02): discovery with the hourly hint and the `last_host` fast
/// path, pinned TLS, the session handshake, reconnection with `RECONNECT_BACKOFF`, network and sleep events, and
/// the 0.11 state machine. One consumer reads `events` (the app's coordinator).
public actor ConnectionManager {
    public nonisolated let events: AsyncStream<LinkEvent>
    let eventSink: AsyncStream<LinkEvent>.Continuation
    let discovery: any LANDiscovering
    let network: any NetworkMonitoring
    let connector: any ChannelConnecting
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
    var workers: [Task<Void, Never>] = []

    public init(localCapability: CapabilityData, discovery: any LANDiscovering = BonjourDiscovery(),
                network: any NetworkMonitoring = PathMonitor(), connector: any ChannelConnecting = WebSocketConnector(),
                configuration: ConnectionConfiguration = ConnectionConfiguration()) {
        self.localCapability = localCapability
        self.discovery = discovery
        self.network = network
        self.connector = connector
        self.configuration = configuration
        (events, eventSink) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    // MARK: - Public API

    /// Starts browsing, watching the network and connecting whenever a phone is paired.
    public func start(phone: PairedPhone?) {
        guard workers.isEmpty else { return }
        self.phone = phone
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
        eventSink.finish()
    }

    /// A pairing finished, or the pair was removed (`nil`).
    public func setPhone(_ newPhone: PairedPhone?) async {
        guard newPhone != phone else { return }
        if newPhone?.pair.pairId != phone?.pair.pairId, let current = session {
            session = nil
            await current.close(bye: newPhone == nil ? .revoked : .shutdown)
        }
        phone = newPhone
        if newPhone == nil { apply(.unpaired) }
        signals.post(.phoneChanged)
    }

    /// "Reconnect Now": skip the backoff wait (CONN-01 field 5, CONN-02 field 4).
    public func reconnectNow() {
        issue = issue == .localNetworkDenied ? issue : nil
        signals.post(.reconnectNow)
    }

    /// The Mac is about to sleep: say goodbye while there is time (CONN-02 E2).
    public func systemWillSleep() async {
        sleeping = true
        signals.post(.sleep)
        if let current = session {
            session = nil
            await current.close(bye: .shutdown)
        }
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

    // MARK: - Watchers

    private func watchNetwork() async {
        for await status in network.updates() {
            let previous = networkPath
            networkPath = status
            let change = switch (previous?.satisfied, status.satisfied) {
            case (true?, false): "down"
            case (false?, true), (nil, true): "up"
            case (nil, false): "down"
            default: previous?.signature == status.signature ? "" : "changed"
            }
            if change.isEmpty { continue }
            BenchLog.event("net", ["change": change])
            signals.post(.network)
        }
    }

    private func watchDiscovery() async {
        for await event in discovery.events() {
            switch event {
            case .results(let phones):
                discovered = phones
                signals.post(.discovery)
            case .state(let state):
                discoveryState = state
                let denied = state == .localNetworkDenied
                if denied != (issue == .localNetworkDenied) {
                    issue = denied ? .localNetworkDenied : nil
                    publishStatus()
                }
            }
        }
    }
}
