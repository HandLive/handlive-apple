import Foundation
import GRDB
import HLProtocol
import Testing
@testable import HLCalls

/// The queries of CALL-04 on the SQLCipher database (0.9.3 `call_log_entry`, `sync_cursor`).
@Suite("Call log store")
struct CallLogStoreTests {
    let pairId = CallLogFixtures.pairId

    @Test("A first sync stores its entries as seen; later missed calls are unseen; the cursor goes with the page")
    func pages() async throws {
        let store = try CallLogFixtures.store()
        let first = CallLogFixtures.page([CallLogFixtures.entry(5119, .outgoing, duration: 62),
                                          CallLogFixtures.entry(5120, .missed)], cursor: "c1")
        #expect(try await store.writePage(first, pairId: pairId, firstSync: true, now: 10) == 2)
        #expect(try await store.cursor(pairId: pairId) == "c1")
        #expect(try await store.lastSync(pairId: pairId) == 10)
        #expect(try await store.unseenMissedCount(pairId: pairId) == 0)
        let next = CallLogFixtures.page([CallLogFixtures.entry(5121, .missed), CallLogFixtures.entry(5122, .incoming)],
                                        cursor: "c2")
        try await store.writePage(next, pairId: pairId, firstSync: false, now: 20)
        #expect(try await store.unseenMissedCount(pairId: pairId) == 1)
        let entries = try await store.entries(pairId: pairId)
        #expect(entries.map(\.entryId) == [5122, 5121, 5120, 5119])
        #expect(entries.first { $0.entryId == 5119 }?.durationS == 62)
        #expect(entries.first { $0.entryId == 5121 }?.isUnseenMissed == true)
    }

    @Test("reset deletes the pair's old call log in the page's transaction (E5); unknown types are left out")
    func reset() async throws {
        let store = try CallLogFixtures.store()
        try await store.writePage(CallLogFixtures.page([CallLogFixtures.entry(1, .incoming)], cursor: "a"), pairId: pairId,
                                  firstSync: true, now: 1)
        let reset = CallLogFixtures.page([CallLogFixtures.entry(7, .missed), CallLogFixtures.entry(8, .unrecognized)],
                                         cursor: "b", reset: true)
        #expect(try await store.writePage(reset, pairId: pairId, firstSync: false, now: 2) == 1)
        #expect(try await store.entries(pairId: pairId).map(\.entryId) == [7])
        #expect(try await store.unseenMissedCount(pairId: pairId) == 0) // a reset counts as a first sync
    }

    @Test("log_new upserts keep seen; only a new entry counts as new")
    func applyNew() async throws {
        let store = try CallLogFixtures.store()
        #expect(try await store.applyNew(CallLogFixtures.entry(9, .missed), pairId: pairId))
        #expect(try await store.unseenMissedCount(pairId: pairId) == 1)
        try await store.markSeen(pairId: pairId, entryId: 9)
        #expect(!(try await store.applyNew(CallLogFixtures.entry(9, .missed, name: "Nguyễn Văn A"), pairId: pairId)))
        let entry = try #require(try await store.entries(pairId: pairId).first)
        #expect(entry.seen && entry.displayName == "Nguyễn Văn A")
        #expect(!(try await store.applyNew(CallLogFixtures.entry(10, .unrecognized), pairId: pairId)))
    }

    @Test("Opening the list sees every missed call; deleting a pair takes its call log and cursor; 90 days kept")
    func seenDeleteAndRetention() async throws {
        let store = try CallLogFixtures.store()
        _ = try await store.applyNew(CallLogFixtures.entry(1, .missed, ts: 1000), pairId: pairId)
        _ = try await store.applyNew(CallLogFixtures.entry(2, .missed, ts: 10_000_000_000), pairId: pairId)
        try await store.markAllMissedSeen(pairId: pairId)
        #expect(try await store.unseenMissedCount(pairId: pairId) == 0)
        try await store.deleteOlderThan(10_000_000_000 - CallLogStore.retentionMs + 1)
        #expect(try await store.entries(pairId: pairId).map(\.entryId) == [2])
        try await store.writePage(CallLogFixtures.page([], cursor: "c"), pairId: pairId, firstSync: true, now: 1)
        try await store.deletePair(pairId)
        #expect(try await store.entries(pairId: pairId).isEmpty)
        #expect(try await store.cursor(pairId: pairId) == nil)
    }

    @Test("The list is newest first and limited to its page")
    func paging() async throws {
        let store = try CallLogFixtures.store()
        let entries = (1...150).map { CallLogFixtures.entry(Int64($0), .incoming) }
        try await store.writePage(CallLogFixtures.page(entries, cursor: "c"), pairId: pairId, firstSync: true, now: 1)
        let page = try await store.entries(pairId: pairId)
        #expect(page.count == CallLogStore.pageSize && page.first?.entryId == 150)
        #expect(try await store.entries(pairId: pairId, limit: 200).count == 150)
    }
}
