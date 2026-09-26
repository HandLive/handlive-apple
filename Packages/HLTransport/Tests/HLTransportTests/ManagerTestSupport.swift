import Foundation
import HLCrypto
import HLProtocol
import Network
import Testing
@testable import HLTransport

/// Discovery whose results the test publishes.
final class FakeDiscovery: LANDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<DiscoveryEvent>.Continuation?
    private var pending: [DiscoveryEvent] = []

    func events() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            let queued = pending
            pending = []
            lock.unlock()
            queued.forEach { continuation.yield($0) }
        }
    }

    func publish(_ event: DiscoveryEvent) {
        lock.lock()
        let current = continuation
        if current == nil { pending.append(event) }
        lock.unlock()
        current?.yield(event)
    }

    static func phone(named name: String, hints: [String]) -> DiscoveredPhone {
        let endpoint = NWEndpoint.service(name: name, type: TransportConstants.serviceType, domain: "local.", interface: nil)
        return DiscoveredPhone(name: name, endpoint: ServiceEndpoint(endpoint),
                               txt: ["v": "1", "h": hints.joined(separator: ",")])
    }
}

/// Network path the test switches.
final class FakeNetwork: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<NetworkPathStatus>.Continuation?

    func updates() -> AsyncStream<NetworkPathStatus> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            continuation.yield(NetworkPathStatus(satisfied: true, signature: "wifi-a"))
        }
    }

    func set(satisfied: Bool, signature: String) {
        lock.lock()
        let current = continuation
        lock.unlock()
        current?.yield(NetworkPathStatus(satisfied: satisfied, signature: signature))
    }
}

/// Connector with a scripted outcome per target; a reachable phone is a `FakePhone` on an in-memory channel.
final class FakeConnector: ChannelConnecting, @unchecked Sendable {
    enum Behavior {
        case phone(FakePhone.HelloAnswer)
        case pinMismatch
        case unreachable
    }

    private let lock = NSLock()
    private let pair: PairContext
    private var behaviors: [ConnectTarget: Behavior] = [:]
    private var defaultBehavior: Behavior = .unreachable
    private(set) var attempts: [ConnectTarget] = []
    private(set) var phones: [FakePhone] = []

    init(pair: PairContext) {
        self.pair = pair
    }

    func set(_ behavior: Behavior, for target: ConnectTarget? = nil) {
        lock.lock()
        if let target { behaviors[target] = behavior } else { defaultBehavior = behavior }
        lock.unlock()
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts.count
    }

    var lastPhone: FakePhone? {
        lock.lock()
        defer { lock.unlock() }
        return phones.last
    }

    private func record(_ target: ConnectTarget) -> Behavior {
        lock.lock()
        defer { lock.unlock() }
        attempts.append(target)
        return behaviors[target] ?? defaultBehavior
    }

    private func keep(_ phone: FakePhone) {
        lock.lock()
        phones.append(phone)
        lock.unlock()
    }

    func connect(to target: ConnectTarget, path: String, policy: CertificatePolicy,
                 timeout: Duration) async throws -> ChannelConnection {
        #expect(path == TransportConstants.controlPath)
        switch record(target) {
        case .pinMismatch: throw ConnectError.pinMismatch
        case .unreachable: throw ConnectError.failed("unreachable")
        case .phone(let answer):
            let (client, phoneChannel) = InMemoryChannel.pair()
            let phone = FakePhone(channel: phoneChannel, pair: pair)
            keep(phone)
            Task {
                if case .welcome = answer { try? await phone.accept() } else { try? await phone.answerHello(answer) }
            }
            return ChannelConnection(channel: client, certificateSHA256: ManagerHarness.pin, host: "192.168.1.23", port: 47800)
        }
    }
}

/// Records manager events and waits for matches.
actor LinkRecorder {
    private(set) var events: [LinkEvent] = []

    init(_ stream: AsyncStream<LinkEvent>) {
        Task { await self.consume(stream) }
    }

    private func consume(_ stream: AsyncStream<LinkEvent>) async {
        for await event in stream { events.append(event) }
    }

    func waitFor(timeout: Duration = .seconds(10), _ match: @Sendable (LinkEvent) -> Bool) async -> LinkEvent? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let event = events.last(where: match) { return event }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func waitForState(_ state: ConnectionState, timeout: Duration = .seconds(10)) async -> LinkStatus? {
        guard case .status(let status)? = await waitFor(timeout: timeout, {
            if case .status(let status) = $0 { return status.state == state }
            return false
        }) else { return nil }
        return status
    }

    var connectedCount: Int {
        events.filter { if case .connected = $0 { return true } else { return false } }.count
    }
}

enum ManagerHarness {
    static let pin = Data(repeating: 0xAB, count: 32)

    static func configuration() -> ConnectionConfiguration {
        var configuration = ConnectionConfiguration()
        configuration.lanDiscoveryGrace = .milliseconds(200)
        configuration.delayScale = 0.01 // RECONNECT_BACKOFF 0.5 s → 5 ms; AUTH_FAILED 300 s → 3 s
        configuration.session = SessionHarness.quick()
        return configuration
    }

    struct Setup {
        let manager: ConnectionManager
        let discovery: FakeDiscovery
        let network: FakeNetwork
        let connector: FakeConnector
        let recorder: LinkRecorder
        let phone: PairedPhone
        let hints: [String]
    }

    static func make(lastHost: String? = nil) async -> Setup {
        let pair = SessionHarness.pair()
        let discovery = FakeDiscovery()
        let network = FakeNetwork()
        let connector = FakeConnector(pair: pair)
        let manager = ConnectionManager(localCapability: SessionHarness.macCapability, discovery: discovery,
                                        network: network, connector: connector, configuration: configuration())
        let recorder = LinkRecorder(manager.events)
        let phone = PairedPhone(pair: pair, certificateSHA256: pin, lastHost: lastHost, lastPort: lastHost == nil ? nil : 47800)
        let hints = (try? DiscoveryHint.acceptedHints(prk: pair.prk, nowMs: HLUUID.currentTimeMs())) ?? []
        return Setup(manager: manager, discovery: discovery, network: network, connector: connector, recorder: recorder,
                     phone: phone, hints: hints)
    }
}
