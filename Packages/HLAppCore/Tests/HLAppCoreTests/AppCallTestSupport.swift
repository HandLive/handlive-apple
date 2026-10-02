import Foundation
import HLProtocol
import HLTransport
import OSLog
@testable import HLAppCore

/// App calls (CALL-05) as the phone sends them, and the capability that puts them in effect.
enum AppCallSamples {
    static let callId = "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"
    static let otherCallId = "0192f3f5-1111-7c2d-8e3f-4a5b6c7d8e91"
    static let startedAt: Int64 = 1_727_150_400_123
    static let telegram = AppCallApp(package: "org.telegram.messenger", label: "Telegram")

    static func ringing(_ callId: String = callId, caller: String? = "Nguyễn Văn A",
                        mode: AppCallAnswerMode = .direct,
                        controls: AppCallControls = AppCallControls(answer: true, decline: true)) -> AppCallData {
        AppCallData(callId: callId, app: telegram, caller: caller, state: .ringing, controls: controls,
                    answerMode: mode, startedAt: startedAt)
    }

    static func ongoing(_ callId: String = callId, caller: String? = "Nguyễn Văn A",
                        controls: AppCallControls = AppCallControls(end: true)) -> AppCallData {
        AppCallData(callId: callId, app: telegram, caller: caller, state: .ongoing, controls: controls,
                    startedAt: startedAt, answeredAt: startedAt + 5000)
    }

    static func ended(_ callId: String = callId, reason: AppCallEndReason, answeredAt: Int64? = nil,
                      caller: String? = "Nguyễn Văn A") -> AppCallData {
        AppCallData(callId: callId, app: telegram, caller: caller, state: .ended, controls: .none, startedAt: startedAt,
                    answeredAt: answeredAt, endedAt: startedAt + 25_000, endReason: reason)
    }

    /// The phone's capability: calls on, and calls from other apps `appCalls` (nil = a build without CALL-05).
    static func capability(appCalls: Bool? = true, enabled: Bool = true) -> CapabilityData {
        CapabilityData(appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
                       features: Features(call: CallFeature(enabled: enabled, canAnswer: true, canEnd: true,
                                                            callerId: true, appCalls: appCalls)))
    }

    /// An `app_call` envelope as the session delivers it.
    static func envelope(_ data: AppCallData, ts: Int64, op: String = "app_call") throws -> IncomingEnvelope {
        let payload = Payload(op: op, data: try HLJSON.convert(from: data))
        return IncomingEnvelope(id: HLUUID.v7(), type: .callEvent, ts: ts, body: .json(payload))
    }

    static func refused(_ code: ErrorCode) -> AckError {
        AckError(code: code, message: "x", details: nil)
    }
}

extension AppCallController {
    /// A controller with short timings, paired and connected to `peer` with `capability`.
    @MainActor
    static func connectedForTest(peer: FakeCallPeer = FakeCallPeer(),
                                 capability: CapabilityData = AppCallSamples.capability(),
                                 clock: TestClock = TestClock()) -> AppCallController {
        let controller = AppCallController(now: { clock.now })
        controller.requestTimeout = .milliseconds(300)
        controller.stateWait = .milliseconds(200)
        controller.reconnectGrace = .milliseconds(150)
        controller.connectionLostDelay = .milliseconds(150)
        controller.setPair(CallSamples.pairId, capability: capability)
        controller.connected(peer: peer, capability: capability)
        return controller
    }
}

/// The `HLBENCH/1` lines this test process logged since `start`: debug builds write them to the unified log, which the
/// process can read back (shared/tools/bench/README.md).
enum BenchLines {
    static func since(_ start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)))
        return entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.category == "bench" }.map(\.composedMessage)
    }
}
