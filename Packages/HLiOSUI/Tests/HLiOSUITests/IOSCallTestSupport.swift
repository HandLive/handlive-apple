import Foundation
import HLAppCore
import HLProtocol
import HLTransport
@testable import HLiOSUI

/// Call notifications recorded instead of shown; `reader` is kept to open generic pushes in tests.
@MainActor
final class StubIOSCallNotifications: IOSCallNotifying {
    private(set) var removedIncoming: [String] = []
    private(set) var staleChecks: [Int64] = []
    private(set) var missed: [(MissedCall, Bool)] = []
    private(set) var removedMissed: [(pairId: String, entryId: Int64?)] = []
    private(set) var removedAll = 0
    private(set) var declineFailed: [String] = []
    private(set) var replyNotSent: [String] = []
    private(set) var lastReader: CallPushReader?

    func removeIncoming(callId: String, reader: @escaping CallPushReader) {
        removedIncoming.append(callId)
        lastReader = reader
    }

    func removeStaleIncoming(nowMs: Int64, reader: @escaping CallPushReader) {
        staleChecks.append(nowMs)
        lastReader = reader
    }

    func postMissed(_ missed: MissedCall, canMessage: Bool) { self.missed.append((missed, canMessage)) }
    func removeMissed(pairId: String, entryId: Int64?) { removedMissed.append((pairId, entryId)) }
    func removeAllCalls() { removedAll += 1 }
    func postDeclineFailed(callId: String) { declineFailed.append(callId) }
    func postReplyNotSent(pairId: String, key: String) { replyNotSent.append(key) }
}

/// A phone that accepts every call command, or never answers.
final class OkCallPeer: CallPeer, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [CallActionRequest] = []
    let answers: Bool

    init(answers: Bool = true) {
        self.answers = answers
    }

    var route: ConnectionRoute { .relay }
    var sent: [CallActionRequest] { lock.withLock { actions } }

    func request<Body: Encodable & Sendable>(_ op: CallEventOp, data: Body, id: String,
                                             timeout: Duration) async throws -> Ack {
        if let action = try? HLJSON.convert(HLJSON.convert(from: data), to: CallActionRequest.self) {
            lock.withLock { actions.append(action) }
        }
        guard answers else {
            try await Task.sleep(for: timeout)
            throw SessionError.timedOut
        }
        return .success(re: id)
    }
}

/// Calls as the phone reports them to an iPhone: Decline only (C7).
enum IOSCallSamples {
    static let callId = "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"

    static func ringing(number: String? = "+84900000123", startedAt: Int64 = 1_727_150_400_123,
                        waiting: Bool = false) -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .ringing, waiting: waiting, number: number,
                      displayName: number == nil ? nil : "Nguyễn Văn A", presentation: number == nil ? .unknown : .allowed,
                      subId: 1, simLabel: nil, waitingNumber: waiting ? "+84900000789" : nil, startedAt: startedAt,
                      controls: CallControls(reject: !waiting))
    }

    static func offhook() -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .offhook, number: "+84900000123",
                      displayName: "Nguyễn Văn A", presentation: .allowed, startedAt: 1_727_150_400_123,
                      answeredAt: 1_727_150_405_000, controls: .none)
    }

    static func idleMissed() -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .idle, number: nil, displayName: nil,
                      presentation: .unknown, startedAt: 1_727_150_400_123, endedAt: 1_727_150_425_000,
                      endReason: .missed, controls: .none)
    }

    static func capability(callLog: Bool = true, canSend: Bool = true) -> CapabilityData {
        CapabilityData(appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
                       features: Features(sms: SmsFeature(enabled: true, canSend: canSend),
                                          call: CallFeature(enabled: true, canAnswer: true, canEnd: true,
                                                            callerId: callLog)))
    }
}
