import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// Revocations that reach the client through the relay: only the phone's signed statement unpairs (PAIR-03 API 4,
/// PAIR-02 E3); pair errors before the handshake over the relay only back off (CONN-03 E9).
@Suite("Connection manager: revocations through the relay")
struct ConnectionManagerRevocationTests {
    /// Notices that must never unpair: no statement, signed by someone else, `by` not the phone, tampered time.
    static func forgedNotices(_ pair: PairContext) throws -> [RelayPairRevocation] {
        let signed = try SessionHarness.signedRevocation(pair)
        let otherSeed = try Hex.decode("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
        return [
            RelayPairRevocation(pairId: pair.pairId, by: pair.serverDeviceId, revokedAt: nil, sig: nil),
            try SessionHarness.signedRevocation(pair, seed: otherSeed), // the relay or a third device signs
            RelayPairRevocation(pairId: pair.pairId, by: pair.clientDeviceId, revokedAt: signed.revokedAt, sig: signed.sig),
            RelayPairRevocation(pairId: pair.pairId, by: pair.serverDeviceId, revokedAt: (signed.revokedAt ?? 0) + 1,
                                sig: signed.sig),
        ]
    }

    @Test("Before the first presence: forged notices are ignored, the phone's signed one unpairs (PAIR-03 API 4)",
          arguments: [false, true])
    func firstPresence(signed: Bool) async throws {
        let setup = await RelayHarness.make(phoneOnline: false)
        let notices = signed ? [try SessionHarness.signedRevocation(setup.phone.pair)]
            : try Self.forgedNotices(setup.phone.pair)
        await setup.relay.replacePresenceOnOpen(with: notices.map(SessionHarness.frame))
        await setup.manager.start(phone: setup.phone)
        if signed {
            #expect(await setup.recorder.waitFor { if case .pairRemoved = $0 { true } else { false } } != nil)
        } else {
            // No presence arrives: after presenceWait the phone counts as offline and the client waits for it.
            #expect(await setup.recorder.waitForState(.waitingPeer) != nil)
            #expect(await setup.recorder.events.allSatisfy { if case .pairRemoved = $0 { false } else { true } })
            #expect(await setup.manager.phone != nil)
        }
        await setup.manager.stop()
    }

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
        let forged = try Self.forgedNotices(setup.phone.pair)
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

    @Test("UNSUPPORTED_VERSION or AUTH_FAILED before the handshake over the relay: message shown, normal backoff (CONN-03 E9)",
          arguments: [ErrorCode.unsupportedVersion, .authFailed])
    func relayRejectionKeepsSchedule(code: ErrorCode) async throws {
        let setup = await RelayHarness.make(phoneOnline: false)
        await setup.relay.setHelloAnswer(.error(code))
        await setup.relay.setPhoneOnline(true)
        await setup.manager.start(phone: setup.phone)
        let issue: LinkIssue = code == .authFailed ? .authFailed : .updateThisApp
        let event = await setup.recorder.waitFor {
            if case .status(let status) = $0 { return status.state == .backoff && status.issue == issue }
            return false
        }
        guard case .status(let status)? = event else {
            Issue.record("no backoff showing \(issue)")
            return
        }
        // RECONNECT_BACKOFF (0.5 s × delayScale 0.01), not a stop and not AUTH_FAILED's 300 s × 0.01 = 3 s.
        let retry = try #require(status.nextRetry)
        #expect(retry.timeIntervalSinceNow < 1)
        #expect(await setup.manager.phone != nil)
        await setup.manager.stop()
    }
}
