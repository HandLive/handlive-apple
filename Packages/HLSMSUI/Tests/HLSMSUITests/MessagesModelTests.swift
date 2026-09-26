import Foundation
import HLProtocol
import HLSMS
import Testing
@testable import HLSMSUI

/// The Messages screens' models over a real encrypted database: the list follows new messages (SMS-03 step 2), a
/// conversation shows its messages oldest first with the placeholders of messages written here (SMS-04 field 6).
@MainActor
@Suite("Messages models")
struct MessagesModelTests {
    static let pairId = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

    static func store() throws -> SmsStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hlsmsui-\(UUID().uuidString)")
        return SmsStore(database: try SmsDatabase(url: folder.appendingPathComponent("handlive.sqlite"),
                                                  key: Data(repeating: 3, count: 32)))
    }

    static func new(_ id: Int, thread: Int64, ts: Int64, body: String = "Chiều nay 3h họp nhé") -> SmsNewData {
        SmsNewData(message: SmsMessageData(messageKey: "sms:\(id)", threadId: thread, address: "+84900000123", body: body,
                                           box: .inbox, ts: ts, read: false, subId: 1),
                   thread: SmsThreadData(threadId: thread, addresses: ["+84900000123"], displayName: "Nguyễn Văn A",
                                         snippet: body, lastTs: ts, unreadCount: 1))
    }

    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("The conversation list follows the database; search and the unread filter narrow it")
    func list() async throws {
        let store = try Self.store()
        let model = MessagesModel(engine: SmsEngine(store: store), store: store)
        model.setPair(Self.pairId)
        try await store.applyNew(Self.new(1, thread: 1, ts: 100), pairId: Self.pairId)
        try await store.applyNew(Self.new(2, thread: 2, ts: 200, body: "Hẹn gặp"), pairId: Self.pairId)
        #expect(await Self.eventually { model.threads.map(\.threadId) == [2, 1] })
        model.searchText = "hẹn"
        #expect(model.visibleThreads.map(\.threadId) == [2])
        model.searchText = ""
        try await store.markLocallyRead(pairId: Self.pairId, threadId: 2)
        model.unreadOnly = true
        #expect(await Self.eventually { model.visibleThreads.map(\.threadId) == [1] })
    }

    @Test("A conversation: messages oldest first, the placeholder of a message written here, the counter")
    func conversation() async throws {
        let store = try Self.store()
        let engine = SmsEngine(store: store)
        engine.setPair(Self.pairId)
        let messages = MessagesModel(engine: engine, store: store)
        messages.setPair(Self.pairId)
        try await store.applyNew(Self.new(1, thread: 1, ts: 100), pairId: Self.pairId)
        try await store.applyNew(Self.new(2, thread: 1, ts: 200), pairId: Self.pairId)
        let conversation = messages.conversation(1)
        #expect(await Self.eventually { conversation.messages.map(\.messageKey) == ["sms:1", "sms:2"] })
        try await store.enqueue(SmsDraft(threadId: 1, addresses: ["+84900000123"], body: "Ok", subId: nil),
                                pairId: Self.pairId, now: 300)
        #expect(await Self.eventually { conversation.placeholders.map(\.body) == ["Ok"] })
        #expect(conversation.counter == "0/160")
        conversation.draft = String(repeating: "a", count: 161)
        #expect(conversation.counter.hasPrefix("161/306"))
        #expect(!conversation.canSend) // the phone is not connected: SMS is not active
    }
}
