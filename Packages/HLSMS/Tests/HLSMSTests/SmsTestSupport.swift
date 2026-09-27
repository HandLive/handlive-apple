import Foundation
import HLProtocol
import HLTransport
@testable import HLSMS

/// A fresh encrypted database in a temporary folder.
enum SmsFixtures {
    static let pairId = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    static let key = Data((0..<32).map { UInt8($0) })

    static func database() throws -> SmsDatabase {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hlsms-\(UUID().uuidString)")
        return try SmsDatabase(url: folder.appendingPathComponent(SmsDatabase.fileName), key: key)
    }

    static func thread(_ id: Int64, lastTs: Int64, unread: Int32 = 0, address: String = "+84900000123",
                       name: String? = "Nguyễn Văn A", snippet: String = "…") -> SmsThreadData {
        SmsThreadData(threadId: id, addresses: [address], displayName: name, snippet: snippet, lastTs: lastTs,
                      unreadCount: unread)
    }

    static func message(_ id: Int, thread: Int64, ts: Int64, box: SmsBox = .inbox, read: Bool = false,
                        body: String = "Chiều nay 3h họp nhé", address: String = "+84900000123",
                        localId: String? = nil) -> SmsMessageData {
        SmsMessageData(messageKey: "sms:\(id)", threadId: thread, address: address, body: body, box: box, ts: ts,
                       read: read, subId: 1, localId: localId)
    }

    static let capability = CapabilityData(
        appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
        features: Features(sms: {
            var sms = SmsFeature(enabled: true, canSend: true)
            sms.sims = [SimInfo(subId: 1, slot: 0, label: "SIM 1"), SimInfo(subId: 2, slot: 1, label: "SIM 2")]
            sms.defaultSubId = 1
            return sms
        }()),
        permissionsMissing: [])
}

/// The phone's side of `sms/*` requests, answered by a script; throwing `SessionError.timedOut` means "no ack".
final class FakeSmsPeer: SmsPeer, @unchecked Sendable {
    struct Request {
        let op: SmsOp
        let data: JSONValue
        let id: String
    }

    typealias Handler = @Sendable (Request) throws -> Ack
    private let lock = NSLock()
    private var handler: Handler
    private var log: [Request] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func request<Body: Encodable & Sendable>(_ op: SmsOp, data: Body, id: String,
                                             timeout: Duration) async throws -> Ack {
        let request = Request(op: op, data: try HLJSON.convert(from: data), id: id)
        return try record(request)(request)
    }

    var route: ConnectionRoute { .lan }

    private func record(_ request: Request) -> Handler {
        lock.lock()
        defer { lock.unlock() }
        log.append(request)
        return handler
    }

    static func success(_ request: Request, _ body: some Encodable) -> Ack {
        Ack.success(re: request.id, data: (try? HLJSON.convert(from: body)) ?? .emptyObject)
    }

    static func failure(_ request: Request, _ code: ErrorCode, details: JSONValue? = nil) -> Ack {
        Ack.failure(re: request.id, error: AckError(code: code, message: "test", details: details))
    }
}

/// An engine on a fresh database with its event log.
@MainActor
struct EngineHarness {
    let engine: SmsEngine
    let store: SmsStore
    let log: EventLog
}

/// Collects engine events.
@MainActor
final class EventLog {
    private(set) var events: [SmsEvent] = []

    func attach(_ engine: SmsEngine) {
        engine.onEvent = { [weak self] in self?.events.append($0) }
    }

    func wait(timeout: Duration = .seconds(3), _ match: (SmsEvent) -> Bool) async -> SmsEvent? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let event = events.last(where: match) { return event }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}

/// Polls an async condition.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
