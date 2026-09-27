import Foundation
import HLAppCore
import HLProtocol
import HLSMS
import HLTransport
@testable import HLCalls

/// A fresh encrypted database and the call log values of the tests.
enum CallLogFixtures {
    static let pairId = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    static let key = Data((0..<32).map { UInt8($0) })

    static func store() throws -> CallLogStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hlcalls-\(UUID().uuidString)")
        return CallLogStore(database: try SmsDatabase(url: folder.appendingPathComponent(SmsDatabase.fileName), key: key))
    }

    static func entry(_ id: Int64, _ type: CallLogType, ts: Int64? = nil, number: String? = "+84900000123",
                      name: String? = nil, duration: Int32 = 0, subId: Int32? = 1) -> CallLogEntryData {
        CallLogEntryData(entryId: id, number: number, displayName: name, type: type, ts: ts ?? id * 1000,
                         durationS: duration, subId: subId)
    }

    static func page(_ entries: [CallLogEntryData], cursor: String, hasMore: Bool = false,
                     reset: Bool = false) -> CallLogSyncAckData {
        CallLogSyncAckData(entries: entries, cursor: cursor, hasMore: hasMore, reset: reset)
    }

    static func capability(callerId: Bool = true, missing: [String] = [], sims: Int = 2) -> CapabilityData {
        var sms = SmsFeature(enabled: true, canSend: true)
        sms.sims = (1...max(1, sims)).map { SimInfo(subId: Int32($0), slot: Int32($0 - 1), label: "SIM \($0)") }
        return CapabilityData(appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
                              features: Features(sms: sms, call: CallFeature(enabled: true, canAnswer: true,
                                                                             canEnd: true, callerId: callerId)),
                              permissionsMissing: missing)
    }

    static func logNew(_ entry: CallLogEntryData, callId: String? = nil) -> IncomingEnvelope {
        let data = (try? HLJSON.convert(from: CallLogNewData(entry: entry, callId: callId))) ?? .emptyObject
        return IncomingEnvelope(id: HLUUID.v7(), type: .callEvent, ts: 1, body: .json(Payload(op: "log_new", data: data)))
    }
}

/// The phone's side of `call_event/log_sync`, answered by a script: a page, an error, or silence (no `ack`).
final class ScriptedCallPeer: CallPeer, @unchecked Sendable {
    enum Reply {
        case page(CallLogSyncAckData)
        case refused(ErrorCode)
        case silence
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var requests: [CallLogSyncRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var route: ConnectionRoute { .lan }

    var sent: [CallLogSyncRequest] { lock.withLock { requests } }

    func request<Body: Encodable & Sendable>(_ op: CallEventOp, data: Body, id: String,
                                             timeout: Duration) async throws -> Ack {
        let reply: Reply = lock.withLock {
            if let request = try? HLJSON.convert(HLJSON.convert(from: data), to: CallLogSyncRequest.self) {
                requests.append(request)
            }
            return replies.isEmpty ? .silence : replies.removeFirst()
        }
        switch reply {
        case .page(let page):
            return .success(re: id, data: try HLJSON.convert(from: page))
        case .refused(let code):
            var details: JSONValue?
            if code == .permissionMissing {
                details = .object(["permission": .string("android.permission.READ_CALL_LOG")])
            }
            return .failure(re: id, error: AckError(code: code, message: "x", details: details))
        case .silence:
            try await Task.sleep(for: timeout)
            throw SessionError.timedOut
        }
    }
}

/// Records the engine's events.
@MainActor
final class CallLogEventLog {
    private(set) var events: [CallLogEvent] = []

    init(_ engine: CallLogEngine) {
        engine.onEvent = { [weak self] in self?.events.append($0) }
    }

    var missed: [MissedCall] {
        events.compactMap { if case .missed(let call) = $0 { return call } else { return nil } }
    }

    var lastBadge: Int? {
        events.compactMap { if case .badge(let count) = $0 { return count } else { return nil } }.last
    }
}

/// Waits (up to 3 s) until `condition` holds.
@MainActor
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
