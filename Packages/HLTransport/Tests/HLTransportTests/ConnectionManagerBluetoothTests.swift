import Foundation
import HLProtocol
import Testing
@testable import HLTransport

/// Task #190 (0.11 "Pre-authentication rule by route", CONN-01 E4, CONN-03 E9, CONN-05 E5): a `session/error`
/// before the phone is authenticated over Bluetooth gets the same treatment as over the relay — `phone` stays set,
/// nothing is removed, and `AUTH_FAILED`/`UNSUPPORTED_VERSION` keep the normal backoff schedule instead of
/// stopping or waiting 5 minutes. No fake Bluetooth radio exists yet (M7.1b/c), so these call `handshakeFailed`
/// directly rather than through a full connect attempt — exactly the route-generic logic CONN-05 E5 needs.
@Suite("Connection manager: pre-authentication errors over Bluetooth (0.11, task #190)")
struct ConnectionManagerBluetoothTests {
    /// `handshakeFailed` is called directly below (no fake Bluetooth radio exists yet to drive a real connect
    /// attempt), but it still needs the machine actually in `.handshaking(.bluetooth)` first — `apply()` is a
    /// no-op off any edge the 0.11 diagram doesn't have, and `idle(.notPaired)` (the state right after `setPhone`)
    /// has no edge for `.handshakeFailed` (task #196, Khoa #3325 / Trang #3326: the original setup() left the
    /// machine in `.idle`, so `apply(.handshakeFailed)` silently did nothing and `waitForState(.backoff)` timed
    /// out). Walk the same two edges a real connect attempt would (`.bluetoothInstanceFound` then
    /// `.linkSecurityVerified`) instead of reaching into the machine directly.
    private func setup() async -> ManagerHarness.Setup {
        let setup = await ManagerHarness.make()
        await setup.manager.setPhone(setup.phone)
        await setup.manager.apply(.bluetoothInstanceFound)
        await setup.manager.apply(.linkSecurityVerified)
        return setup
    }

    @Test("PAIR_UNKNOWN or PAIR_REVOKED over Bluetooth before authentication → Backoff, the pair stays",
          arguments: [ErrorCode.pairUnknown, .pairRevoked])
    func bluetoothPairErrorBacksOff(code: ErrorCode) async throws {
        let setup = await setup()
        await setup.manager.handshakeFailed(SessionEstablishError.rejected(code, minProtocol: nil), route: .bluetooth)
        #expect(await setup.recorder.waitForState(.backoff) != nil)
        #expect(await setup.recorder.events.allSatisfy { if case .pairRemoved = $0 { false } else { true } })
        #expect(await setup.manager.phone != nil)
    }

    @Test("UNSUPPORTED_VERSION or AUTH_FAILED over Bluetooth before authentication: message shown, normal backoff",
          arguments: [ErrorCode.unsupportedVersion, .authFailed])
    func bluetoothRejectionKeepsSchedule(code: ErrorCode) async throws {
        let setup = await setup()
        // minProtocol: 2 for UNSUPPORTED_VERSION, same as FakePhone.answerHello's realistic rejection (> the
        // package's currentProtocolVersion of 1) — `nil` always reads as "update the phone", never "update this
        // app" (+Backoff.swift:61), so a real session/error for this code always carries one (task #196).
        let failure: SessionEstablishError = code == .authFailed ? .authFailed : .rejected(code, minProtocol: 2)
        await setup.manager.handshakeFailed(failure, route: .bluetooth)
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
    }
}
