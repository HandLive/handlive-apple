import Foundation
import HLProtocol
import Testing
@testable import HLTransport

@Suite("Connection manager: rejections, losses, sleep (CONN-01 E3–E5, CONN-02)")
struct ConnectionManagerFailureTests {
    private static func isConnected(_ event: LinkEvent) -> Bool {
        if case .connected = event { return true }
        return false
    }

    private func connectedSetup(answer: FakePhone.HelloAnswer = .welcome) async -> ManagerHarness.Setup {
        let setup = await ManagerHarness.make()
        let instance = FakeDiscovery.phone(named: "HL-4f9a2c", hints: [setup.hints[0]])
        setup.connector.set(.phone(answer), for: .service(instance.endpoint))
        setup.discovery.publish(.results([instance]))
        await setup.manager.start(phone: setup.phone)
        return setup
    }

    @Test("PAIR_UNKNOWN → the pair is removed and the client goes Idle (CONN-01 E4)")
    func pairUnknown() async throws {
        let setup = await connectedSetup(answer: .error(.pairUnknown))
        let removed = await setup.recorder.waitFor {
            if case .pairRemoved(.unknownToPhone) = $0 { return true } else { return false }
        }
        #expect(removed != nil)
        #expect(await setup.recorder.waitForState(.idle(.notPaired)) != nil)
        await setup.manager.stop()
    }

    @Test("AUTH_FAILED → Backoff for five minutes with the issue shown (E3)")
    func authFailed() async throws {
        let setup = await connectedSetup(answer: .error(.authFailed))
        let status = await setup.recorder.waitFor {
            if case .status(let status) = $0 { return status.state == .backoff && status.issue == .authFailed }
            return false
        }
        guard case .status(let backoff)? = status, let retry = backoff.nextRetry else {
            Issue.record("no backoff with AUTH_FAILED")
            return
        }
        #expect(retry.timeIntervalSinceNow > 2) // 300 s × delayScale 0.01
        await setup.manager.stop()
    }

    @Test("UNSUPPORTED_VERSION with min_protocol 2 → update this app, no automatic retry (E5)")
    func updateRequired() async throws {
        let setup = await connectedSetup(answer: .error(.unsupportedVersion))
        let status = await setup.recorder.waitFor {
            if case .status(let status) = $0 { return status.issue == .updateThisApp && status.state == .backoff }
            return false
        }
        guard case .status(let backoff)? = status else {
            Issue.record("no update prompt")
            return
        }
        #expect(backoff.nextRetry == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(setup.connector.attemptCount == 1)
        await setup.manager.stop()
    }

    @Test("Connection lost → Backoff → Connected again (CONN-02 steps 3–5)")
    func reconnectsAfterLoss() async throws {
        let setup = await connectedSetup()
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        let firstPhone = try #require(setup.connector.lastPhone)
        await firstPhone.channel.close(code: .idleTimeout) // 4411
        #expect(await setup.recorder.waitFor { if case .disconnected = $0 { return true } else { return false } } != nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await setup.recorder.connectedCount < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await setup.recorder.connectedCount == 2)
        await setup.manager.stop()
    }

    @Test("Network lost while connected → Idle(no network); back → Connected")
    func networkLossAndReturn() async throws {
        let setup = await connectedSetup()
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        setup.network.set(satisfied: false, signature: "")
        #expect(await setup.recorder.waitForState(.idle(.noNetwork)) != nil)
        setup.network.set(satisfied: true, signature: "wifi-b")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await setup.recorder.connectedCount < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await setup.recorder.connectedCount == 2)
        await setup.manager.stop()
    }

    @Test("pair/revoke from the phone → ack, bye revoked, pair removed (PAIR-03 step 6)")
    func revokedByPhone() async throws {
        let setup = await connectedSetup()
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        let phone = try #require(setup.connector.lastPhone)
        _ = try await phone.send(.pair, op: "revoke", data: PairRevokeData(pairId: setup.phone.pair.pairId, reason: .user))
        #expect(try await phone.receiveAck().ok)
        let (_, bye) = try await phone.receiveJSON()
        #expect(try bye.decodeData(as: SessionByeData.self).reason == .revoked)
        let removed = await setup.recorder.waitFor {
            if case .pairRemoved(.revokedByPhone) = $0 { return true } else { return false }
        }
        #expect(removed != nil)
        #expect(await setup.recorder.waitForState(.idle(.notPaired)) != nil)
        await setup.manager.stop()
    }

    @Test("Sleep says bye {shutdown}; wake reconnects at once (CONN-02 E2)")
    func sleepAndWake() async throws {
        let setup = await connectedSetup()
        #expect(await setup.recorder.waitFor({ Self.isConnected($0) }) != nil)
        let phone = try #require(setup.connector.lastPhone)
        await setup.manager.systemWillSleep()
        let (_, bye) = try await phone.receiveJSON()
        #expect(try bye.decodeData(as: SessionByeData.self).reason == .shutdown)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await setup.recorder.connectedCount == 1) // no reconnect while asleep
        await setup.manager.systemDidWake()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await setup.recorder.connectedCount < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await setup.recorder.connectedCount == 2)
        await setup.manager.stop()
    }

    @Test("HLBENCH/1 line format (shared/tools/bench/README.md)")
    func benchLine() {
        let line = BenchLog.line(wallMs: 1_727_151_142_000.5, monoNs: 5_042_000_000_000,
                                 identity: BenchLog.Identity(device: "5b1f8c2e", role: .macos),
                                 event: "state", fields: [("from", "Discovering"), ("to", "Connected"), ("x", "a b")])
        #expect(line == "HLBENCH/1 wall=1727151142000.500 mono=5042000000000 dev=5b1f8c2e role=macos ev=state "
                + "from=Discovering to=Connected x=a_b")
        #expect(ConnectionState.connected(.lan).benchName == "Connected")
        #expect(ConnectionState.idle(.needsRepair).benchName == "Idle")
    }
}
