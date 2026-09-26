import Foundation
import HLProtocol
import Testing
@testable import HLTransport

@Suite("Connection manager (CONN-01, CONN-02, 0.11)")
struct ConnectionManagerTests {
    private static func isConnected(_ event: LinkEvent) -> Bool {
        if case .connected = event { return true }
        return false
    }

    @Test("mDNS instance with this hour's hint → pinned connection → Connected, last_host reported")
    func connectsThroughDiscovery() async throws {
        let setup = await ManagerHarness.make()
        let instance = FakeDiscovery.phone(named: "HL-4f9a2c", hints: ["1a2b3c4d", setup.hints[0]])
        setup.connector.set(.phone(.welcome), for: .service(instance.endpoint))
        setup.discovery.publish(.results([FakeDiscovery.phone(named: "HL-000000", hints: ["deadbeef"]), instance]))
        await setup.manager.start(phone: setup.phone)
        guard case .connected(_, let details)? = await setup.recorder.waitFor({ Self.isConnected($0) }) else {
            Issue.record("not connected")
            return
        }
        #expect(details.host == "192.168.1.23" && details.port == 47800 && details.route == .lan)
        #expect(details.peerCapability == FakePhone.androidCapability)
        #expect(await setup.recorder.waitForState(.connected(.lan)) != nil)
        #expect(setup.connector.attempts == [.service(instance.endpoint)]) // the foreign instance was never tried
        await setup.manager.stop()
    }

    @Test("last_host is tried first and connects without waiting for mDNS")
    func fastPath() async throws {
        let setup = await ManagerHarness.make(lastHost: "192.168.1.23")
        setup.connector.set(.phone(.welcome), for: .host("192.168.1.23", port: 47800))
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        #expect(setup.connector.attempts.first == .host("192.168.1.23", port: 47800))
        await setup.manager.stop()
    }

    @Test("A failing fast path falls back to mDNS instead of backing off")
    func fastPathFallsBack() async throws {
        let setup = await ManagerHarness.make(lastHost: "10.0.0.9")
        let instance = FakeDiscovery.phone(named: "HL-4f9a2c", hints: [setup.hints[0]])
        setup.connector.set(.phone(.welcome), for: .service(instance.endpoint))
        setup.discovery.publish(.results([instance]))
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        #expect(setup.connector.attempts == [.host("10.0.0.9", port: 47800), .service(instance.endpoint)])
        await setup.manager.stop()
    }

    @Test("Nothing on the LAN for LAN_DISCOVERY_GRACE → Backoff; the phone reappearing ends the wait early")
    func graceThenBackoff() async throws {
        let setup = await ManagerHarness.make()
        await setup.manager.start(phone: setup.phone)
        let backoff = await setup.recorder.waitForState(.backoff)
        #expect(backoff?.nextRetry != nil)
        let instance = FakeDiscovery.phone(named: "HL-4f9a2c", hints: [setup.hints[0]])
        setup.connector.set(.phone(.welcome), for: .service(instance.endpoint))
        setup.discovery.publish(.results([instance]))
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        await setup.manager.stop()
    }

    @Test("Every instance fails the pin → Needs re-pairing, no retries until Reconnect Now (CONN-01 E2)")
    func needsRepair() async throws {
        let setup = await ManagerHarness.make()
        let instance = FakeDiscovery.phone(named: "HL-4f9a2c", hints: [setup.hints[0]])
        setup.connector.set(.pinMismatch, for: .service(instance.endpoint))
        setup.discovery.publish(.results([instance]))
        await setup.manager.start(phone: setup.phone)
        let status = await setup.recorder.waitForState(.idle(.needsRepair))
        #expect(status?.status == .needsRepair)
        try await Task.sleep(for: .milliseconds(300))
        #expect(setup.connector.attemptCount == 1)
        setup.connector.set(.phone(.welcome), for: .service(instance.endpoint))
        await setup.manager.reconnectNow()
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        await setup.manager.stop()
    }

    @Test("One instance fails the pin, the next one is ours")
    func skipsMismatchedInstance() async throws {
        let setup = await ManagerHarness.make()
        let stale = FakeDiscovery.phone(named: "HL-111111", hints: [setup.hints[0]])
        let real = FakeDiscovery.phone(named: "HL-222222", hints: [setup.hints[1]])
        setup.connector.set(.pinMismatch, for: .service(stale.endpoint))
        setup.connector.set(.phone(.welcome), for: .service(real.endpoint))
        setup.discovery.publish(.results([stale, real]))
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        await setup.manager.stop()
    }

    @Test("Unreachable instance → Backoff → retried after RECONNECT_BACKOFF")
    func retriesAfterBackoff() async throws {
        let setup = await ManagerHarness.make()
        let instance = FakeDiscovery.phone(named: "HL-4f9a2c", hints: [setup.hints[0]])
        setup.connector.set(.unreachable, for: .service(instance.endpoint))
        setup.discovery.publish(.results([instance]))
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.backoff) != nil)
        setup.connector.set(.phone(.welcome), for: .service(instance.endpoint))
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        #expect(setup.connector.attemptCount >= 2)
        await setup.manager.stop()
    }
}
