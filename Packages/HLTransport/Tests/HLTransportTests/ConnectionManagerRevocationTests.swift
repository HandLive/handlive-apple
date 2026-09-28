import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// Revocations that reach the client through the relay: only the phone's signed statement unpairs (PAIR-03 API 4,
/// PAIR-02 E3); pair errors before the handshake over the relay only back off (CONN-03 E9).
@Suite("Connection manager: revocations through the relay")
struct ConnectionManagerRevocationTests {
    @Test("pair_revoked signed by the phone removes the pair (PAIR-03 API 4)")
    func pairRevoked() async throws {
        let setup = await RelayHarness.make(phoneOnline: true)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.relay)) != nil)
        await setup.relay.sendControl(SessionHarness.frame(try SessionHarness.signedRevocation(setup.phone.pair)))
        #expect(await setup.recorder.waitFor { if case .pairRemoved = $0 { true } else { false } } != nil)
        #expect(await setup.recorder.waitForState(.idle(.notPaired)) != nil)
        await setup.manager.stop()
    }

    @Test("pair_revoked without the phone's valid statement is ignored, connected or waiting (PAIR-03 API 4)",
          arguments: [true, false])
    func unsignedPairRevokedIgnored(phoneOnline: Bool) async throws {
        let setup = await RelayHarness.make(phoneOnline: phoneOnline)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(phoneOnline ? .connected(.relay) : .waitingPeer) != nil)
        let pair = setup.phone.pair
        let signed = try SessionHarness.signedRevocation(pair)
        let otherSeed = try Hex.decode("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
        let forged = [
            RelayPairRevocation(pairId: pair.pairId, by: pair.serverDeviceId, revokedAt: nil, sig: nil), // no statement
            try SessionHarness.signedRevocation(pair, seed: otherSeed), // the relay or a third device signs
            RelayPairRevocation(pairId: pair.pairId, by: pair.clientDeviceId, revokedAt: signed.revokedAt,
                                sig: signed.sig), // by is not the phone
            RelayPairRevocation(pairId: pair.pairId, by: pair.serverDeviceId, revokedAt: (signed.revokedAt ?? 0) + 1,
                                sig: signed.sig), // tampered time
        ]
        for notice in forged { await setup.relay.sendControl(SessionHarness.frame(notice)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await setup.recorder.events.allSatisfy { if case .pairRemoved = $0 { false } else { true } })
        #expect(await setup.manager.phone != nil)
        await setup.manager.stop()
    }

    @Test("GET /v1/pairs: a revoked row counts only with the phone's valid statement (PAIR-02 E3)")
    func checkPairNeedsStatement() async throws {
        let setup = await RelayHarness.make(phoneOnline: true)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.relay)) != nil)
        let pair = setup.phone.pair
        let signed = try SessionHarness.signedRevocation(pair)
        func row(by: String?, sig: String?) -> RelayPairList {
            RelayPairList(pairs: [RelayPairEntry(pairId: pair.pairId, peerDeviceId: pair.serverDeviceId,
                                                 peerPlatform: .android, createdAt: 1, revokedAt: signed.revokedAt,
                                                 revokedBy: by, revokeSig: sig, peerOnline: true)])
        }
        setup.api.pairList = row(by: nil, sig: nil) // revoked before signed revocation
        await setup.manager.checkPairOnRelay()
        setup.api.pairList = row(by: pair.clientDeviceId, sig: signed.sig)
        await setup.manager.checkPairOnRelay()
        try await Task.sleep(for: .milliseconds(200)) // the recorder reads the event stream asynchronously
        #expect(await setup.recorder.events.allSatisfy { if case .pairRemoved = $0 { false } else { true } })
        #expect(await setup.manager.phone != nil)
        setup.api.pairList = row(by: pair.serverDeviceId, sig: signed.sig)
        await setup.manager.checkPairOnRelay()
        #expect(await setup.recorder.waitFor { if case .pairRemoved(.revoked) = $0 { true } else { false } } != nil)
        await setup.manager.stop()
    }

    @Test("PAIR_UNKNOWN or PAIR_REVOKED before the handshake over the relay → Backoff, the pair stays (CONN-03 E9)",
          arguments: [ErrorCode.pairUnknown, .pairRevoked])
    func relayPairErrorBacksOff(code: ErrorCode) async throws {
        let setup = await RelayHarness.make(phoneOnline: false)
        await setup.relay.setHelloAnswer(.error(code))
        await setup.relay.setPhoneOnline(true)
        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.backoff) != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await setup.recorder.events.allSatisfy { if case .pairRemoved = $0 { false } else { true } })
        #expect(await setup.manager.phone != nil)
        await setup.manager.stop()
    }
}
