import Foundation
import HLProtocol
import Testing
@testable import HLTransport

@Suite("Connection manager: RECONNECT_BACKOFF resets only after a stable session (0.10, CONN-05)")
struct ConnectionManagerBackoffTests {
    private func connectedSetup(stableAfter: Duration) async -> ManagerHarness.Setup {
        var configuration = ManagerHarness.configuration()
        configuration.backoffResetAfter = stableAfter
        let setup = await ManagerHarness.make(configuration: configuration)
        let instance = FakeDiscovery.phone(named: "HL-4f9a2c", hints: [setup.hints[0]])
        setup.connector.set(.phone(.welcome), for: .service(instance.endpoint))
        setup.discovery.publish(.results([instance]))
        await setup.manager.start(phone: setup.phone)
        return setup
    }

    private func waitForConnections(_ count: Int, _ setup: ManagerHarness.Setup) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await setup.recorder.connectedCount < count && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("A session that drops before it is stable keeps the current backoff step")
    func shortSessionsKeepTheStep() async throws {
        let setup = await connectedSetup(stableAfter: .seconds(30))
        for round in 1...3 {
            await waitForConnections(round, setup)
            #expect(await setup.recorder.connectedCount == round)
            let phone = try #require(setup.connector.lastPhone)
            await phone.channel.close(code: .idleTimeout)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await setup.manager.backoff.attempt < round && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(await setup.manager.backoff.attempt == 3)
        await setup.manager.stop()
    }

    @Test("A session that stays Connected for the reset time starts the backoff again from the first step")
    func stableSessionResetsTheStep() async throws {
        let setup = await connectedSetup(stableAfter: .milliseconds(300))
        for round in 1...2 {
            await waitForConnections(round, setup)
            let phone = try #require(setup.connector.lastPhone)
            await phone.channel.close(code: .idleTimeout)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await setup.manager.backoff.attempt < round && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        await waitForConnections(3, setup)
        #expect(await setup.manager.backoff.attempt == 2) // not reset right away
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await setup.manager.backoff.attempt != 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await setup.manager.backoff.attempt == 0)
        await setup.manager.stop()
    }
}
