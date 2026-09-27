import Foundation
import HLProtocol
import HLTransport
import Testing
@testable import HLSMS

/// SMS-01 and SMS-02/SMS-05 through the engine against a scripted phone.
@MainActor
@Suite("SMS engine: sync, new messages, read state")
struct SmsEngineSyncTests {
    let pairId = SmsFixtures.pairId

    func engine() throws -> EngineHarness {
        let store = SmsStore(database: try SmsFixtures.database())
        let engine = SmsEngine(store: store)
        engine.providerRetryDelay = .milliseconds(10)
        engine.setPair(pairId)
        let log = EventLog()
        log.attach(engine)
        return EngineHarness(engine: engine, store: store, log: log)
    }

    nonisolated static func page(_ request: FakeSmsPeer.Request, _ page: SmsSyncAckData) -> Ack {
        FakeSmsPeer.success(request, page)
    }

    @Test("First sync: two pages looped by page_token with the same cursor, then the cursor and done")
    func firstSync() async throws {
        let harness = try engine()
        let (engine, store, log) = (harness.engine, harness.store, harness.log)
        let peer = FakeSmsPeer { request in
            let sync = try HLJSON.convert(request.data, to: SmsSyncRequest.self)
            if sync.pageToken == nil {
                return Self.page(request, SmsSyncAckData(threads: [SmsFixtures.thread(1, lastTs: 20, unread: 1)],
                                                         messages: [SmsFixtures.message(2, thread: 1, ts: 20)],
                                                         cursor: "c9", pageToken: "p1", hasMore: true))
            }
            return Self.page(request, SmsSyncAckData(threads: [], messages: [SmsFixtures.message(1, thread: 1, ts: 10)],
                                                     cursor: "c9", hasMore: false,
                                                     unread: [SmsReadState(threadId: 1, unreadCount: 1, readUpToTs: 19)]))
        }
        engine.connected(peer: peer, capability: SmsFixtures.capability)
        #expect(await log.wait { $0 == .syncStatus(.done) } != nil)
        let requests = peer.requests.filter { $0.op == .sync }.map { try? HLJSON.convert($0.data, to: SmsSyncRequest.self) }
        #expect(requests == [SmsSyncRequest(cursor: nil), SmsSyncRequest(cursor: nil, pageToken: "p1")])
        #expect(try await store.cursor(pairId: pairId) == "c9")
        #expect(log.events.contains(.syncStatus(.syncing(downloaded: 1, firstSync: true))))
        #expect(await log.wait { $0 == .badge(1) } != nil) // published after `done`, once the count is read
        #expect(log.events.contains(.removeNotifications(pairId: pairId, threadId: 1, upToTs: 19)))
        #expect(log.events.contains(.removeGenericNotifications))
        #expect(!log.events.contains { if case .notify = $0 { true } else { false } }) // no notifications from sync
    }

    @Test("E5: a stale page_token restarts from the stored cursor; a stale cursor resyncs everything")
    func cursorInvalid() async throws {
        let harness = try engine()
        let (engine, store, log) = (harness.engine, harness.store, harness.log)
        try await store.applySyncPage(SmsSyncAckData(threads: [SmsFixtures.thread(5, lastTs: 1)],
                                                     messages: [SmsFixtures.message(50, thread: 5, ts: 1)],
                                                     cursor: "old", hasMore: false, unread: []), pairId: pairId, now: 1)
        let calls = Counter()
        let peer = FakeSmsPeer { request in
            switch calls.next() {
            case 0: return FakeSmsPeer.failure(request, .smsCursorInvalid, details: .object(["reason": .string("cursor")]))
            default: return Self.page(request, SmsSyncAckData(threads: [], messages: [], cursor: "new", hasMore: false,
                                                              unread: []))
            }
        }
        engine.connected(peer: peer, capability: SmsFixtures.capability)
        #expect(await log.wait { $0 == .syncStatus(.done) } != nil)
        let cursors = peer.requests.map { (try? HLJSON.convert($0.data, to: SmsSyncRequest.self))?.cursor }
        #expect(cursors == ["old", nil])
        #expect(try await store.threads(pairId: pairId).isEmpty) // A2 cleared the old data
        #expect(try await store.cursor(pairId: pairId) == "new")
    }

    @Test("E1, E2, E4, E6: off on the phone, missing READ_SMS, no ack, a provider error retried once")
    func failures() async throws {
        let harness = try engine()
        let (engine, log) = (harness.engine, harness.log)
        engine.connected(peer: FakeSmsPeer { FakeSmsPeer.failure($0, .featureDisabled) }, capability: SmsFixtures.capability)
        #expect(await log.wait { $0 == .syncStatus(.failed(.featureOff)) } != nil)
        engine.disconnected()
        engine.connected(peer: FakeSmsPeer { FakeSmsPeer.failure($0, .permissionMissing) }, capability: SmsFixtures.capability)
        #expect(await log.wait { $0 == .syncStatus(.failed(.permissionMissing)) } != nil)
        engine.disconnected()
        engine.connected(peer: FakeSmsPeer { _ in throw SessionError.timedOut }, capability: SmsFixtures.capability)
        #expect(await log.wait { $0 == .syncStatus(.failed(.interrupted)) } != nil)
        engine.disconnected()
        let calls = Counter()
        engine.connected(peer: FakeSmsPeer { request in
            calls.next() == 0 ? FakeSmsPeer.failure(request, .internal)
                : Self.page(request, SmsSyncAckData(threads: [], messages: [], cursor: "c", hasMore: false, unread: []))
        }, capability: SmsFixtures.capability)
        #expect(await log.wait { $0 == .syncStatus(.done) } != nil)
    }

    @Test("SMS is inactive without READ_SMS in permissions_missing: no sync")
    func inactive() async throws {
        let harness = try engine()
        let (engine, log) = (harness.engine, harness.log)
        let capability = CapabilityData(appVersion: "1", platform: .android, osVersion: "15", model: "P",
                                        features: SmsFixtures.capability.features, permissionsMissing: ["READ_SMS"])
        let peer = FakeSmsPeer { FakeSmsPeer.failure($0, .internal) }
        engine.connected(peer: peer, capability: capability)
        #expect(await log.wait { $0 == .syncStatus(.failed(.permissionMissing)) } != nil)
        #expect(peer.requests.isEmpty && !engine.isActive)
    }

    @Test("SMS-02: a new inbox message notifies once, not for the open conversation, not with sms.notify off")
    func newMessages() async throws {
        let harness = try engine()
        let (engine, log) = (harness.engine, harness.log)
        engine.connected(peer: FakeSmsPeer { Self.page($0, SmsSyncAckData(threads: [], messages: [], cursor: "c",
                                                                          hasMore: false, unread: [])) },
                         capability: SmsFixtures.capability)
        let new = SmsNewData(message: SmsFixtures.message(7, thread: 3, ts: 70), thread: SmsFixtures.thread(3, lastTs: 70,
                                                                                                          unread: 1))
        engine.receive(Self.envelope(.new, new))
        let notify = await log.wait { if case .notify = $0 { true } else { false } }
        guard case .notify(let incoming)? = notify else {
            Issue.record("no notification")
            return
        }
        #expect(incoming.message.messageKey == "sms:7" && incoming.simLabel == "SIM 1" && incoming.pairId == pairId)
        engine.receive(Self.envelope(.new, new)) // the same message again: no second notification
        engine.openThreadId = 3
        engine.receive(Self.envelope(.new, SmsNewData(message: SmsFixtures.message(8, thread: 3, ts: 80),
                                                      thread: SmsFixtures.thread(3, lastTs: 80, unread: 2))))
        engine.openThreadId = nil
        engine.notifyEnabled = { false }
        engine.receive(Self.envelope(.new, SmsNewData(message: SmsFixtures.message(9, thread: 4, ts: 90),
                                                      thread: SmsFixtures.thread(4, lastTs: 90, unread: 1))))
        #expect(await log.wait { $0 == .badge(2) } != nil)
        #expect(log.events.filter { if case .notify = $0 { true } else { false } }.count == 1)
    }

    @Test("SMS-05: read_changed updates the conversation and removes read notifications; opening reads locally")
    func readState() async throws {
        let harness = try engine()
        let (engine, store, log) = (harness.engine, harness.store, harness.log)
        try await store.applyNew(SmsNewData(message: SmsFixtures.message(1, thread: 1, ts: 10),
                                            thread: SmsFixtures.thread(1, lastTs: 10, unread: 1)), pairId: pairId)
        engine.receive(Self.envelope(.readChanged, SmsReadState(threadId: 1, unreadCount: 0, readUpToTs: 11)))
        #expect(await log.wait { $0 == .removeNotifications(pairId: pairId, threadId: 1, upToTs: 11) } != nil)
        #expect(await log.wait { $0 == .badge(0) } != nil)
        try await store.applyNew(SmsNewData(message: SmsFixtures.message(2, thread: 1, ts: 20),
                                            thread: SmsFixtures.thread(1, lastTs: 20, unread: 1)), pairId: pairId)
        await engine.openConversation(threadId: 1)
        #expect(log.events.last == .badge(0))
        #expect(log.events.contains(.removeNotifications(pairId: pairId, threadId: 1, upToTs: nil)))
    }

    nonisolated static func envelope(_ op: SmsOp, _ data: some Encodable) -> IncomingEnvelope {
        let payload = Payload(op: op.rawValue, data: (try? HLJSON.convert(from: data)) ?? .emptyObject)
        return IncomingEnvelope(id: HLUUID.v7(), type: .sms, ts: HLUUID.currentTimeMs(), body: .json(payload))
    }
}

/// Thread-safe counter for scripted answers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value - 1
    }
}
