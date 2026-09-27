import Foundation
import GRDB
import HLProtocol
import Testing
@testable import HLSMS

/// The queries of 05-sms.md on the SQLCipher database (0.9.3).
@Suite("SMS store (SQLCipher through GRDB)")
struct SmsStoreTests {
    let pairId = SmsFixtures.pairId

    @Test("The file is encrypted with db_key: no plaintext, no SQLite header, a wrong key cannot open it")
    func encrypted() async throws {
        let database = try SmsFixtures.database()
        let store = SmsStore(database: database)
        let page = SmsSyncAckData(threads: [SmsFixtures.thread(42, lastTs: 10)],
                                  messages: [SmsFixtures.message(1, thread: 42, ts: 10, body: "secret-marker-42")],
                                  cursor: "c1", hasMore: false, unread: [])
        try await store.applySyncPage(page, pairId: pairId, now: 1)
        let version = try await database.pool.read { try String.fetchOne($0, sql: "PRAGMA cipher_version") }
        #expect(version?.isEmpty == false)
        _ = try await database.pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        let raw = try Data(contentsOf: database.url)
        #expect(raw.range(of: Data("secret-marker-42".utf8)) == nil)
        #expect(raw.range(of: Data("SQLite format 3".utf8)) == nil)
        try database.pool.close()
        #expect(throws: (any Error).self) { _ = try SmsDatabase(url: database.url, key: Data(repeating: 9, count: 32)) }
        #expect(throws: SmsDatabaseError.invalidKey) { _ = try SmsDatabase(url: database.url, key: Data(count: 16)) }
    }

    @Test("SMS-01: pages upsert, the cursor is saved only on the last page, local_read_ts and local_id are kept")
    func syncPages() async throws {
        let store = SmsStore(database: try SmsFixtures.database())
        try await store.enqueue(SmsDraft(localId: "0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f",
                                         threadId: 42, addresses: ["+84900000123"], body: "Ok anh",
                                         subId: 1), pairId: pairId, now: 1_000)
        let first = SmsSyncAckData(threads: [SmsFixtures.thread(42, lastTs: 2_000, unread: 1)],
                                   messages: [SmsFixtures.message(2, thread: 42, ts: 2_000),
                                              SmsFixtures.message(1, thread: 42, ts: 1_500, box: .sent, read: true,
                                                                  body: "Ok anh")],
                                   cursor: "c2", pageToken: "p1", hasMore: true)
        try await store.applySyncPage(first, pairId: pairId, now: 5)
        #expect(try await store.cursor(pairId: pairId) == nil)
        try await store.markLocallyRead(pairId: pairId, threadId: 42)
        let last = SmsSyncAckData(threads: [SmsFixtures.thread(42, lastTs: 2_000, unread: 1, name: "A")],
                                  messages: [], cursor: "c2", hasMore: false,
                                  unread: [SmsReadState(threadId: 42, unreadCount: 1, readUpToTs: 1_999)])
        try await store.applySyncPage(last, pairId: pairId, now: 6)
        #expect(try await store.cursor(pairId: pairId) == "c2")
        #expect(try await store.lastSync(pairId: pairId) == 6)
        let thread = try #require(try await store.thread(pairId: pairId, threadId: 42))
        #expect(thread.localReadTs == 2_000 && thread.displayName == "A" && !thread.isUnread)
        let messages = try await store.messages(pairId: pairId, threadId: 42)
        #expect(messages.map(\.messageKey) == ["sms:2", "sms:1"])
        // The sent copy matched the placeholder of this device (API 4 logic 3) and settled it as sent.
        #expect(messages[1].localId == "0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f" && messages[1].sendState == .sent)
        #expect(try await store.placeholders(pairId: pairId, threadId: 42).isEmpty)
    }

    @Test("SMS-01 step 9: conversations missing from unread become read, the others follow read_up_to_ts")
    func unreadReconciliation() async throws {
        let store = SmsStore(database: try SmsFixtures.database())
        let page = SmsSyncAckData(
            threads: [SmsFixtures.thread(1, lastTs: 30, unread: 2), SmsFixtures.thread(2, lastTs: 40, unread: 1)],
            messages: [SmsFixtures.message(10, thread: 1, ts: 10), SmsFixtures.message(11, thread: 1, ts: 20),
                       SmsFixtures.message(12, thread: 1, ts: 30), SmsFixtures.message(20, thread: 2, ts: 40)],
            cursor: "c", hasMore: false, unread: [SmsReadState(threadId: 1, unreadCount: 1, readUpToTs: 29)])
        try await store.applySyncPage(page, pairId: pairId, now: 1)
        #expect(try await store.thread(pairId: pairId, threadId: 2)?.unreadCount == 0)
        let flags = try await store.messages(pairId: pairId, threadId: 1).map(\.read)
        #expect(flags == [false, true, true]) // ts 30 unread, 20 and 10 read
        #expect(try await store.messages(pairId: pairId, threadId: 2).first?.read == true)
        #expect(try await store.unreadThreadCount(pairId: pairId) == 1)
    }

    @Test("A2: a resync drops messages, conversations, cursor and completed entries, keeps what still waits")
    func resync() async throws {
        let store = SmsStore(database: try SmsFixtures.database())
        try await store.enqueue(SmsDraft(localId: "0192f3e2-0000-7000-8000-000000000001",
                                         threadId: 1, addresses: ["+1"], body: "waiting",
                                         subId: nil), pairId: pairId, now: 1)
        try await store.enqueue(SmsDraft(localId: "0192f3e2-0000-7000-8000-000000000002",
                                         threadId: 1, addresses: ["+1"], body: "done",
                                         subId: nil), pairId: pairId, now: 2)
        try await store.transition(localId: "0192f3e2-0000-7000-8000-000000000002", to: .sent, now: 3)
        try await store.applySyncPage(SmsSyncAckData(threads: [SmsFixtures.thread(1, lastTs: 5)],
                                                     messages: [SmsFixtures.message(1, thread: 1, ts: 5)],
                                                     cursor: "c", hasMore: false, unread: []), pairId: pairId, now: 4)
        try await store.resetForResync(pairId: pairId)
        #expect(try await store.cursor(pairId: pairId) == nil)
        #expect(try await store.threads(pairId: pairId).isEmpty)
        #expect(try await store.pending(pairId: pairId).map(\.body) == ["waiting"])
        #expect(try await store.outboxEntry(localId: "0192f3e2-0000-7000-8000-000000000002") == nil)
    }

    @Test("SMS-02, SMS-03: a new row is reported once; history never overwrites; read state and local read")
    func newHistoryAndRead() async throws {
        let store = SmsStore(database: try SmsFixtures.database())
        let new = SmsNewData(message: SmsFixtures.message(7, thread: 3, ts: 70), thread: SmsFixtures.thread(3, lastTs: 70,
                                                                                                          unread: 1))
        #expect(try await store.applyNew(new, pairId: pairId))
        #expect(try await !store.applyNew(new, pairId: pairId))
        try await store.insertHistory([SmsFixtures.message(7, thread: 3, ts: 70, body: "changed"),
                                       SmsFixtures.message(6, thread: 3, ts: 60, read: true)], pairId: pairId)
        let messages = try await store.messages(pairId: pairId, threadId: 3)
        #expect(messages.map(\.body) == ["Chiều nay 3h họp nhé", "Chiều nay 3h họp nhé"] && messages.count == 2)
        #expect(try await store.oldestTimestamp(pairId: pairId, threadId: 3) == 60)
        #expect(try await store.unreadThreadCount(pairId: pairId) == 1)
        try await store.markLocallyRead(pairId: pairId, threadId: 3)
        #expect(try await store.unreadThreadCount(pairId: pairId) == 0)
        try await store.applyReadState(SmsReadState(threadId: 99, unreadCount: 3, readUpToTs: 1), pairId: pairId) // E4
        try await store.applyReadState(SmsReadState(threadId: 3, unreadCount: 0, readUpToTs: 100), pairId: pairId)
        #expect(try await store.messages(pairId: pairId, threadId: 3).allSatisfy(\.read))
        let unknown = SmsFixtures.message(8, thread: 3, ts: 80, box: .unrecognized)
        try await store.applyNew(SmsNewData(message: unknown, thread: SmsFixtures.thread(3, lastTs: 80)), pairId: pairId)
        #expect(try await store.messages(pairId: pairId, threadId: 3).count == 2) // a box of a newer phone is skipped
    }

    @Test("Paging: conversations by last_ts and messages by (ts, message_key), 50 at a time")
    func paging() async throws {
        let store = SmsStore(database: try SmsFixtures.database())
        let threads = (1...60).map { SmsFixtures.thread(Int64($0), lastTs: Int64($0 % 30)) }
        let messages = (1...60).map { SmsFixtures.message($0, thread: 1, ts: Int64($0 / 2)) }
        try await store.applySyncPage(SmsSyncAckData(threads: threads, messages: messages, cursor: "c", hasMore: false,
                                                     unread: []), pairId: pairId, now: 1)
        let first = try await store.threads(pairId: pairId)
        let second = try await store.threads(pairId: pairId, after: first.last)
        #expect(first.count == 50 && second.count == 10 && Set((first + second).map(\.threadId)).count == 60)
        #expect(first.first?.lastTs == 29)
        let page1 = try await store.messages(pairId: pairId, threadId: 1)
        let page2 = try await store.messages(pairId: pairId, threadId: 1, before: page1.last)
        #expect(page1.count == 50 && page2.count == 10 && Set((page1 + page2).map(\.messageKey)).count == 60)
    }

    @Test("PAIR-03 step 7: deleting a pair removes only its rows")
    func deletePair() async throws {
        let store = SmsStore(database: try SmsFixtures.database())
        let other = "7a6b5c4d-3e2f-4a1b-9c8d-7e6f5a4b3c2d"
        for pair in [pairId, other] {
            try await store.applyNew(SmsNewData(message: SmsFixtures.message(1, thread: 1, ts: 1),
                                                thread: SmsFixtures.thread(1, lastTs: 1)), pairId: pair)
        }
        try await store.deletePair(pairId)
        #expect(try await store.threads(pairId: pairId).isEmpty)
        #expect(try await store.threads(pairId: other).count == 1)
        try await store.deleteAll()
        #expect(try await store.threads(pairId: other).isEmpty)
    }
}
