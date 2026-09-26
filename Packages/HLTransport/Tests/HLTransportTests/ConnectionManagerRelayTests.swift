import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// A manager whose relay is a `FakeRelay` with a `FakePhone` behind it.
enum RelayHarness {
    struct Setup {
        let manager: ConnectionManager
        let discovery: FakeDiscovery
        let connector: FakeConnector
        let relay: FakeRelay
        let api: FakeRelayAPI
        let recorder: LinkRecorder
        let phone: PairedPhone
        let hints: [String]
    }

    static func make(phoneOnline: Bool, registration: RelayPairRegistration? = nil) async -> Setup {
        let pair = SessionHarness.pair()
        let discovery = FakeDiscovery()
        let connector = FakeConnector(pair: pair)
        let relay = FakeRelay(pair: pair)
        let api = FakeRelayAPI()
        if phoneOnline { await relay.setPhoneOnline(true) }
        var configuration = ManagerHarness.configuration()
        configuration.presenceWait = .milliseconds(300)
        configuration.upgradeGrace = .milliseconds(50)
        let manager = ConnectionManager(localCapability: SessionHarness.macCapability, discovery: discovery,
                                        network: FakeNetwork(), connector: connector,
                                        relay: RelayServices(api: api, sockets: relay), configuration: configuration)
        let phone = PairedPhone(pair: pair, certificateSHA256: ManagerHarness.pin, relayRegistration: registration)
        let hints = (try? DiscoveryHint.acceptedHints(prk: pair.prk, nowMs: HLUUID.currentTimeMs())) ?? []
        return Setup(manager: manager, discovery: discovery, connector: connector, relay: relay, api: api,
                     recorder: LinkRecorder(manager.events), phone: phone, hints: hints)
    }
}

@Suite("Connection manager through the relay (CONN-03, CONN-04 wake, 0.11)")
struct ConnectionManagerRelayTests {
    static func connectedDetails(_ recorder: LinkRecorder) async -> LinkDetails? {
        guard case .connected(_, let details)? = await recorder.waitFor({
            if case .connected = $0 { return true } else { return false }
        }) else { return nil }
        return details
    }

    @Test("Silent LAN → relay → phone online → handshake through the relay → Connected over the internet")
    func connectsThroughRelay() async throws {
        let setup = await RelayHarness.make(phoneOnline: true)
        await setup.manager.start(phone: setup.phone)
        let details = await Self.connectedDetails(setup.recorder)
        #expect(details?.route == .relay && details?.host == nil && details?.port == nil)
        #expect(await setup.recorder.waitForState(.connected(.relay)) != nil)
        #expect(await setup.relay.forwarded.allSatisfy { $0 == setup.phone.pair.serverDeviceId })
        #expect(setup.api.pushCount == 0)
        await setup.manager.stop()
    }

    @Test("Phone offline → WaitingPeer with one wake push; presence online → Connected (E5)")
    func waitsForThePhone() async throws {
        let setup = await RelayHarness.make(phoneOnline: false)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.waitingPeer) != nil)
        #expect(await waitUntil { setup.api.pushCount == 1 })
        let push = try #require(setup.api.pushes.first)
        #expect(push.kind == .wake && push.reason == .userOpen && push.to == setup.phone.pair.serverDeviceId)
        await setup.relay.setPhoneOnline(true)
        #expect(await setup.recorder.waitForState(.connected(.relay)) != nil)
        await setup.manager.wakePhone(reason: .userOpen)
        #expect(setup.api.pushCount == 1) // connected: no more wakes
        await setup.manager.stop()
    }

    @Test("The phone leaves the relay while connected → back to WaitingPeer (E8)")
    func phoneLeaves() async throws {
        let setup = await RelayHarness.make(phoneOnline: true)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.relay)) != nil)
        await setup.relay.setPhoneOnline(false)
        #expect(await setup.recorder.waitForState(.waitingPeer) != nil)
        await setup.relay.setPhoneOnline(true)
        #expect(await setup.recorder.waitFor { event in
            if case .status(let status) = event { return status.state == .connected(.relay) } else { return false }
        } != nil)
        await setup.manager.stop()
    }

    @Test("A pair not yet on the relay is registered first (CONN-03 step 3)")
    func registersPair() async throws {
        let registration = RelayPairRegistration(pairId: SessionHarness.pair().pairId, deviceA: "a", deviceB: "b",
                                                 createdAt: 1, attestation: "x", sigA: "y", sigB: "z")
        let setup = await RelayHarness.make(phoneOnline: true, registration: registration)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitFor {
            if case .relayPairRegistered(let pairId) = $0 { return pairId == registration.pairId } else { return false }
        } != nil)
        #expect(setup.api.registeredPairs == [registration])
        await setup.manager.stop()
    }

    @Test("410 DEVICE_REVOKED turns the relay off (E3); a pin failure is reported and not retried (E7); 429 waits (E6)")
    func relayRefusals() async throws {
        let revoked = await RelayHarness.make(phoneOnline: true)
        revoked.api.fail(with: .http(status: 410, code: .deviceRevoked, retryAfter: nil))
        await revoked.manager.start(phone: revoked.phone)
        #expect(await revoked.recorder.waitFor { $0.isRelayDeviceRevoked } != nil)
        let status = await revoked.recorder.waitFor {
            if case .status(let status) = $0 { return status.issue == .relayDeviceRemoved } else { return false }
        }
        #expect(status != nil)
        await revoked.manager.stop()

        let untrusted = await RelayHarness.make(phoneOnline: true)
        untrusted.api.fail(with: .pinMismatch)
        await untrusted.manager.start(phone: untrusted.phone)
        #expect(await untrusted.recorder.waitFor {
            if case .status(let status) = $0 { return status.issue == .relayUntrusted } else { return false }
        } != nil)
        #expect(await untrusted.relay.opens == 0)
        await untrusted.manager.stop()

        let limited = await RelayHarness.make(phoneOnline: true)
        limited.api.fail(with: .http(status: 429, code: .rateLimited, retryAfter: 30))
        await limited.manager.start(phone: limited.phone)
        let waiting = await limited.recorder.waitFor {
            if case .status(let status) = $0 { return status.issue == .relayRateLimited && status.nextRetry != nil }
            return false
        }
        #expect(waiting != nil) // E6: "Trying again in …" from nextRetry
        await limited.manager.stop()
    }

    @Test("relay.enabled off: the grace ends in Backoff and no relay is opened")
    func relayDisabled() async throws {
        let setup = await RelayHarness.make(phoneOnline: true)
        await setup.manager.start(phone: setup.phone, relayEnabled: false)
        #expect(await setup.recorder.waitForState(.backoff) != nil)
        #expect(await setup.relay.opens == 0)
        await setup.manager.setRelayEnabled(true)
        #expect(await setup.recorder.waitForState(.connected(.relay)) != nil)
        await setup.manager.setRelayEnabled(false)
        #expect(await setup.recorder.waitForState(.backoff) != nil)
        await setup.manager.stop()
    }

    @Test("pair_revoked from the relay removes the pair (PAIR-03 API 4)")
    func pairRevoked() async throws {
        let setup = await RelayHarness.make(phoneOnline: true)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.relay)) != nil)
        await setup.relay.sendControl(#"{"op":"pair_revoked","pair_id":"\#(setup.phone.pair.pairId)","#
            + #""by":"\#(setup.phone.pair.serverDeviceId)"}"#)
        #expect(await setup.recorder.waitFor { if case .pairRemoved = $0 { true } else { false } } != nil)
        #expect(await setup.recorder.waitForState(.idle(.notPaired)) != nil)
        await setup.manager.stop()
    }

    @Test("On the relay, the phone showing up on the LAN moves the session there (CONN-02 step 7)")
    func upgradesToLAN() async throws {
        let setup = await RelayHarness.make(phoneOnline: true)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.relay)) != nil)
        let instance = FakeDiscovery.phone(named: "HL-4f9a2c", hints: [setup.hints[1]])
        setup.connector.set(.phone(.welcome), for: .service(instance.endpoint))
        setup.discovery.publish(.results([instance]))
        #expect(await setup.recorder.waitForState(.connected(.lan)) != nil)
        #expect(await setup.recorder.connectedCount == 2)
        await setup.manager.stop()
    }
}

extension LinkEvent {
    var isRelayDeviceRevoked: Bool {
        if case .relayDeviceRevoked = self { return true }
        return false
    }
}

/// Polls a condition for up to `timeout`.
func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
