import Foundation
import HLProtocol
import HLTransport
import Testing
@testable import HLSMS

/// SMS-04 and SMS-03 through the engine: outbox, retries with the same envelope id, errors, statuses, history.
@MainActor
@Suite("SMS engine: sending and older messages")
struct SmsEngineSendTests {
    let pairId = SmsFixtures.pairId

    func engine() throws -> EngineHarness {
        let store = SmsStore(database: try SmsFixtures.database())
        let engine = SmsEngine(store: store)
        engine.retryDelays = [.milliseconds(10), .milliseconds(10), .milliseconds(10)]
        engine.requestTimeout = .milliseconds(50)
        engine.setPair(pairId)
        let log = EventLog()
        log.attach(engine)
        return EngineHarness(engine: engine, store: store, log: log)
    }

    nonisolated static func handler(send: @escaping @Sendable (FakeSmsPeer.Request) throws -> Ack) -> FakeSmsPeer.Handler {
        { request in
            switch request.op {
            case .sync: FakeSmsPeer.success(request, SmsSyncAckData(threads: [], messages: [], cursor: "c", hasMore: false,
                                                                    unread: []))
            default: try send(request)
            }
        }
    }

    @Test("Offline: the message waits as pending and asks for a wake-up; the next session sends it (E1, CONN-02)")
    func offlineThenFlush() async throws {
        let harness = try engine()
        let (engine, store, log) = (harness.engine, harness.store, harness.log)
        engine.setPair(pairId, capability: SmsFixtures.capability) // the stored capability: default SIM 1
        let localId = try await engine.send(text: " Ok, 3h mình có mặt ", to: "+84900000123", threadId: 42, subId: nil)
        #expect(log.events.contains(.needsPhone))
        let waiting = try #require(try await store.outboxEntry(localId: localId))
        #expect(waiting.state == .pending && waiting.body == "Ok, 3h mình có mặt" && waiting.subId == 1)
        let peer = FakeSmsPeer(Self.handler { FakeSmsPeer.success($0, SmsSendAckData(accepted: true, parts: 1)) })
        engine.connected(peer: peer, capability: SmsFixtures.capability)
        #expect(await eventually { (try? await store.outboxEntry(localId: localId))?.state == .sending })
        let send = try #require(peer.requests.first { $0.op == .send })
        let request = try HLJSON.convert(send.data, to: SmsSendRequest.self)
        #expect(request == SmsSendRequest(localId: localId, threadId: 42, addresses: ["+84900000123"],
                                          body: "Ok, 3h mình có mặt", subId: 1))
    }

    @Test("No ack: resent with the same envelope id after each retry delay, then kept pending (step 5, E1)")
    func retriesWithSameId() async throws {
        let harness = try engine()
        let (engine, store) = (harness.engine, harness.store)
        let peer = FakeSmsPeer(Self.handler { _ in throw SessionError.timedOut })
        engine.connected(peer: peer, capability: SmsFixtures.capability)
        let localId = try await engine.send(text: "hello", to: "+1234", threadId: nil, subId: 2)
        #expect(await eventually { peer.requests.filter { $0.op == .send }.count == 4 })
        let ids = Set(peer.requests.filter { $0.op == .send }.map(\.id))
        #expect(ids.count == 1)
        try await Task.sleep(for: .milliseconds(100))
        let entry = try #require(try await store.outboxEntry(localId: localId))
        #expect(entry.state == .pending && entry.attempts == 4)
    }

    @Test("Error acks fail the message with their code (E2–E6); statuses move it forward only (API 2)")
    func errorsAndStatuses() async throws {
        let harness = try engine()
        let (engine, store) = (harness.engine, harness.store)
        let peer = FakeSmsPeer(Self.handler { request in
            let body = try HLJSON.convert(request.data, to: SmsSendRequest.self).body
            return body == "bad" ? FakeSmsPeer.failure(request, .smsSimUnavailable, details: .object(["sims": .array([.int(1)])]))
                : FakeSmsPeer.success(request, SmsSendAckData(accepted: true, parts: 1))
        })
        engine.connected(peer: peer, capability: SmsFixtures.capability)
        let failed = try await engine.send(text: "bad", to: "+1234", threadId: 1, subId: 9)
        let good = try await engine.send(text: "good", to: "+1234", threadId: 1, subId: nil)
        #expect(await eventually { (try? await store.outboxEntry(localId: good))?.state == .sending })
        let failure = try #require(try await store.outboxEntry(localId: failed))
        #expect(failure.state == .failed && failure.errorCode == .smsSimUnavailable)
        engine.receive(SmsEngineSyncTests.envelope(.status, SmsStatusData(localId: good, status: .delivered)))
        #expect(await eventually { (try? await store.outboxEntry(localId: good))?.state == .delivered })
        engine.receive(SmsEngineSyncTests.envelope(.status, SmsStatusData(localId: good, status: .sent)))
        engine.receive(SmsEngineSyncTests.envelope(.status, SmsStatusData(localId: good, status: .failed,
                                                                         errorCode: .smsNoService)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await store.outboxEntry(localId: good)?.state == .delivered)
        let retried = try #require(try await engine.retry(localId: failed)) // A1: a new local_id
        let oldEntry = try await store.outboxEntry(localId: failed)
        #expect(retried != failed && oldEntry == nil)
    }

    @Test("Composer checks: empty text, group conversations (E5, E9)")
    func composerChecks() async throws {
        let engine = try engine().engine
        await #expect(throws: SmsComposeError.invalidText) {
            try await engine.send(text: "  ", to: "+1234", threadId: nil, subId: nil)
        }
        let group = SmsThread(pairId: pairId, threadId: 9, addressesJSON: #"["+1","+2"]"#, displayName: nil,
                              snippet: nil, lastTs: 1, unreadCount: 0, localReadTs: 0)
        await #expect(throws: SmsComposeError.groupConversation) { try await engine.reply(text: "hi", in: group, subId: nil) }
    }

    @Test("Quick reply waits for the phone's ack; without a session it stays pending and says so (B3, E8)")
    func quickReply() async throws {
        let harness = try engine()
        let (engine, store) = (harness.engine, harness.store)
        let accepted = await engine.quickReply(text: "later", to: "+1234", threadId: 5, subId: nil,
                                               deadline: .milliseconds(200))
        #expect(!accepted)
        #expect(try await store.pendingCount(pairId: pairId) == 1)
        engine.connected(peer: FakeSmsPeer(Self.handler { FakeSmsPeer.success($0, SmsSendAckData(accepted: true, parts: 1)) }),
                         capability: SmsFixtures.capability)
        let now = await engine.quickReply(text: "now", to: "+1234", threadId: 5, subId: nil, deadline: .seconds(2))
        #expect(now)
    }

    @Test("SMS-03: older messages page by page; E3 ends the conversation; E2 loads after reconnecting")
    func history() async throws {
        let harness = try engine()
        let (engine, store, log) = (harness.engine, harness.store, harness.log)
        try await store.applyNew(SmsNewData(message: SmsFixtures.message(10, thread: 1, ts: 1_000),
                                            thread: SmsFixtures.thread(1, lastTs: 1_000)), pairId: pairId)
        engine.loadOlder(threadId: 1)
        #expect(log.events.last == .history(threadId: 1, .needsConnection))
        let peer = FakeSmsPeer(Self.handler { request in
            let history = try HLJSON.convert(request.data, to: SmsHistoryRequest.self)
            if history.threadId == 2 { return FakeSmsPeer.failure(request, .smsThreadNotFound) }
            #expect(history.beforeTs == 1_000 && history.limit == 50)
            return FakeSmsPeer.success(request, SmsHistoryAckData(messages: [SmsFixtures.message(9, thread: 1, ts: 900)],
                                                                  hasMore: false))
        })
        engine.connected(peer: peer, capability: SmsFixtures.capability)
        #expect(await log.wait { $0 == .history(threadId: 1, .complete) } != nil)
        #expect(try await store.messages(pairId: pairId, threadId: 1).count == 2)
        #expect(!engine.mayHaveOlder(threadId: 1))
        engine.loadOlder(threadId: 2)
        #expect(await log.wait { $0 == .history(threadId: 2, .threadGone) } != nil)
    }
}
