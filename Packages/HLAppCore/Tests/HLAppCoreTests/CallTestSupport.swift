import Foundation
import HLProtocol
import HLTransport
@testable import HLAppCore

/// A phone for the call tests: records every `call_event` request and answers with a scripted `ack`, or never answers
/// (`nil`), or fails like a session that ended.
final class FakeCallPeer: CallPeer, @unchecked Sendable {
    enum Reply {
        case ok
        case refused(AckError)
        case silence
        case sessionEnded
    }

    struct Sent: Equatable {
        let op: CallEventOp
        let id: String
        let data: JSONValue
    }

    private let lock = NSLock()
    private var sentRequests: [Sent] = []
    private var replies: [Reply]
    private let fallback: Reply

    init(_ replies: [Reply] = [], otherwise fallback: Reply = .silence) {
        self.replies = replies
        self.fallback = fallback
    }

    var route: ConnectionRoute { .lan }

    var sent: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return sentRequests
    }

    func request<Body: Encodable & Sendable>(_ op: CallEventOp, data: Body, id: String,
                                             timeout: Duration) async throws -> Ack {
        let reply: Reply = lock.withLock {
            sentRequests.append(Sent(op: op, id: id, data: (try? HLJSON.convert(from: data)) ?? .emptyObject))
            return replies.isEmpty ? fallback : replies.removeFirst()
        }
        switch reply {
        case .ok:
            return .success(re: id)
        case .refused(let error):
            return .failure(re: id, error: error)
        case .silence:
            try await Task.sleep(for: timeout)
            throw SessionError.timedOut
        case .sessionEnded:
            throw SessionError.ended
        }
    }
}

/// States and capabilities of the call tests.
enum CallSamples {
    static let pairId = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    static let callId = "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"
    static let otherCallId = "0192f3f5-1111-7c2d-8e3f-4a5b6c7d8e91"
    static let startedAt: Int64 = 1_727_150_400_123

    static func ringing(_ callId: String = callId, number: String? = "+84900000123", name: String? = "Nguyễn Văn A",
                        presentation: CallPresentation = .allowed) -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .ringing, number: number, displayName: name,
                      presentation: presentation, subId: 1, simLabel: "SIM 1", startedAt: startedAt,
                      controls: CallControls(answer: true, reject: true))
    }

    static func offhook(_ callId: String = callId, answeredAt: Int64 = startedAt + 5000) -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .offhook, number: "+84900000123",
                      displayName: "Nguyễn Văn A", presentation: .allowed, subId: 1, simLabel: "SIM 1",
                      startedAt: startedAt, answeredAt: answeredAt, controls: CallControls(end: true))
    }

    static func waiting() -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .ringing, waiting: true, number: "+84900000123",
                      displayName: "Nguyễn Văn A", presentation: .allowed, waitingNumber: "+84900000456",
                      startedAt: startedAt, answeredAt: startedAt + 5000, controls: .none)
    }

    static func idle(_ callId: String = callId, reason: CallEndReason, answeredAt: Int64? = nil,
                     number: String? = "+84900000123") -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .idle, number: number,
                      displayName: number == nil ? nil : "Nguyễn Văn A", presentation: number == nil ? .unknown : .allowed,
                      subId: 1, simLabel: "SIM 1", startedAt: startedAt, answeredAt: answeredAt,
                      endedAt: startedAt + 25_000, endReason: reason, controls: .none)
    }

    static func capability(callLog: Bool = true, enabled: Bool = true, missing: [String] = []) -> CapabilityData {
        CapabilityData(appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
                       features: Features(call: CallFeature(enabled: enabled, canAnswer: true, canEnd: true,
                                                            callerId: callLog)),
                       permissionsMissing: missing)
    }

    static func refused(_ code: ErrorCode, state: CallPhoneState? = nil,
                        reason: CallActionNotAllowedDetails.Reason? = nil) -> AckError {
        var details: JSONValue?
        if let state, let reason {
            details = try? HLJSON.convert(from: CallActionNotAllowedDetails(state: state, reason: reason))
        }
        return AckError(code: code, message: "x", details: details)
    }
}

/// Records the controller's events.
@MainActor
final class CallEventLog {
    private(set) var events: [CallEvent] = []

    init(_ controller: CallController) {
        controller.onEvent = { [weak self] in self?.events.append($0) }
    }
}

extension CallController {
    /// A controller with short timings, paired and connected to `peer` with `capability`.
    @MainActor
    static func connectedForTest(peer: FakeCallPeer = FakeCallPeer(),
                                 capability: CapabilityData = CallSamples.capability(),
                                 clock: TestClock = TestClock()) -> CallController {
        let controller = CallController(now: { clock.now })
        controller.requestTimeout = .milliseconds(300)
        controller.stateWait = .milliseconds(200)
        controller.endedDisplay = .milliseconds(150)
        controller.reconnectGrace = .milliseconds(150)
        controller.setPair(CallSamples.pairId, capability: capability)
        controller.connected(peer: peer, capability: capability)
        return controller
    }
}

/// A settable clock in Unix ms.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_727_150_401_000

    var now: Int64 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Waits (up to 2 s) until `condition` holds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
