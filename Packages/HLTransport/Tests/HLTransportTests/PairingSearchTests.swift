import Foundation
import HLCrypto
import HLProtocol
import Network
import Testing
@testable import HLTransport

/// Connector for `/v1/pair`: each connection is served by the next scripted phone, or fails.
final class FakePairingConnector: ChannelConnecting, @unchecked Sendable {
    enum Step {
        case phone(FakePairingPhone)
        case unreachable
    }

    private let lock = NSLock()
    private var steps: [Step]
    private let fallback: Step
    private(set) var targets: [ConnectTarget] = []

    init(_ steps: [Step], then fallback: Step = .unreachable) {
        self.steps = steps
        self.fallback = fallback
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return targets.count
    }

    private func next(_ target: ConnectTarget) -> Step {
        lock.lock()
        defer { lock.unlock() }
        targets.append(target)
        return steps.isEmpty ? fallback : steps.removeFirst()
    }

    func connect(to target: ConnectTarget, path: String, policy: CertificatePolicy,
                 timeout: Duration) async throws -> ChannelConnection {
        #expect(path == TransportConstants.pairPath && policy == .recordAny)
        switch next(target) {
        case .unreachable:
            throw ConnectError.failed("unreachable")
        case .phone(let phone):
            let (client, phoneEnd) = InMemoryChannel.pair()
            Task { _ = await phone.serve(phoneEnd) }
            return ChannelConnection(channel: client, certificateSHA256: phone.tlsSHA256, host: "192.168.1.23", port: 47801)
        }
    }
}

/// Collects progress values in order.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PairingProgress] = []

    func add(_ value: PairingProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [PairingProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("Finding the phone's pairing window (PAIR-01 steps 7–8, A2)")
struct PairingSearchTests {
    let identity: PairingIdentity
    let secret = PairingCodes.newPairingSecret()

    init() throws {
        identity = try PairingFixtures.identity()
    }

    /// Polls `condition` for up to five seconds: CI machines schedule tasks slowly.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static func instance(_ name: String, txt: [String: String]) -> DiscoveredPhone {
        let endpoint = NWEndpoint.service(name: name, type: TransportConstants.serviceType, domain: "local.", interface: nil)
        return DiscoveredPhone(name: name, endpoint: ServiceEndpoint(endpoint), txt: ["v": "1"].merging(txt) { $1 })
    }

    func search(_ connector: FakePairingConnector, discovery: FakeDiscovery) -> PairingSearch {
        var search = PairingSearch(discovery: discovery, connector: connector)
        search.retryDelay = .milliseconds(20)
        search.unreachableAfter = .milliseconds(150)
        search.pinParameters = PairingFixtures.smallPIN
        return search
    }

    @Test("QR: connects only to the instance whose TXT pr matches this code")
    func matchesPairingHint() async throws {
        let phone = FakePairingPhone(window: .qr(secret: secret, clientDHKey: identity.dhPublicKey))
        let connector = FakePairingConnector([.phone(phone)])
        let discovery = FakeDiscovery()
        let hint = PairingAuthDerivation.pairingRequestHint(clientDHPublicKey: identity.dhPublicKey)
        let other = Self.instance("other", txt: ["pr": "00000000"])
        let mine = Self.instance("mine", txt: ["pr": hint])
        discovery.publish(.results([other]))
        let log = ProgressLog()
        let task = Task { [identity, secret] in
            try await search(connector, discovery: discovery).run(identity: identity, credential: .qr(secret: secret),
                                                                  offerTimeout: .seconds(5), progress: log.add)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(connector.attemptCount == 0)
        discovery.publish(.results([other, mine]))
        let result = try await task.value
        #expect(result.phoneDeviceId == phone.deviceId)
        #expect(connector.targets == [.service(mine.endpoint)])
        #expect(log.all == [.waitingForPhone, .connecting, .verifying])
    }

    @Test("PIN: any instance with pm = 1; PAIRING_CLOSED and dropped connections are retried")
    func pinRetries() async throws {
        let closed = FakePairingPhone(window: .pin("042917"), fault: .closed)
        let good = FakePairingPhone(window: .pin("042917"))
        let connector = FakePairingConnector([.phone(closed), .unreachable, .phone(good)])
        let discovery = FakeDiscovery()
        discovery.publish(.results([Self.instance("phone", txt: ["pm": "1"])]))
        let result = try await search(connector, discovery: discovery).run(
            identity: identity, credential: .pin("042917", attemptsLeft: 3), offerTimeout: .seconds(5)) { _ in }
        #expect(result.phoneDeviceId == good.deviceId)
        #expect(connector.attemptCount == 3)
    }

    @Test("A wrong PIN and AUTH_FAILED end the search for the caller to handle")
    func endsOnAuthenticationFailures() async throws {
        let discovery = FakeDiscovery()
        discovery.publish(.results([Self.instance("phone", txt: ["pm": "1"])]))
        let wrongPIN = FakePairingConnector([.phone(FakePairingPhone(window: .pin("000000")))])
        await #expect(throws: PairingFailure.pinInvalid(attemptsLeft: 1)) {
            try await search(wrongPIN, discovery: discovery).run(
                identity: identity, credential: .pin("042917", attemptsLeft: 2), offerTimeout: .seconds(5)) { _ in }
        }
        let qrDiscovery = FakeDiscovery()
        let hint = PairingAuthDerivation.pairingRequestHint(clientDHPublicKey: identity.dhPublicKey)
        qrDiscovery.publish(.results([Self.instance("phone", txt: ["pr": hint])]))
        let forged = FakePairingPhone(window: .qr(secret: secret, clientDHKey: identity.dhPublicKey), fault: .wrongOfferMac)
        await #expect(throws: PairingFailure.authFailed) {
            try await search(FakePairingConnector([.phone(forged)]), discovery: qrDiscovery).run(
                identity: identity, credential: .qr(secret: secret), offerTimeout: .seconds(5)) { _ in }
        }
    }

    @Test("E3: the window is visible but unreachable for the grace period; local network denied is reported")
    func unreachableAndDenied() async throws {
        let discovery = FakeDiscovery()
        discovery.publish(.state(.localNetworkDenied))
        let log = ProgressLog()
        let task = Task { [identity, secret] in
            try await search(FakePairingConnector([]), discovery: discovery).run(
                identity: identity, credential: .qr(secret: secret), offerTimeout: .seconds(5), progress: log.add)
        }
        #expect(await Self.eventually { log.all.last == .localNetworkDenied })
        discovery.publish(.state(.ready))
        let hint = PairingAuthDerivation.pairingRequestHint(clientDHPublicKey: identity.dhPublicKey)
        discovery.publish(.results([Self.instance("phone", txt: ["pr": hint])]))
        #expect(await Self.eventually { log.all.contains(.phoneUnreachable) })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
