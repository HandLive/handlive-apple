import Foundation
import GRDB
import HLProtocol
import HLSMS

/// One conversation (SMS-03 steps 3–12, SMS-04): stored messages newest page first, the placeholders of messages
/// written here, older pages from the phone, and the compose field with its SIM and part counter.
@MainActor
public final class ConversationModel: ObservableObject {
    /// Messages oldest first, for display.
    @Published public private(set) var messages: [SmsMessage] = []
    /// Messages written here that the phone has not echoed yet (SMS-04 field 6).
    @Published public private(set) var placeholders: [SmsOutboxEntry] = []
    @Published public private(set) var thread: SmsThread?
    @Published public internal(set) var historyState: SmsHistoryState?
    @Published public var draft = "" {
        didSet { counter = SmsDisplay.counter(for: draft) }
    }
    /// SMS-04 field 3.
    @Published public private(set) var counter = SmsDisplay.counter(for: "")
    /// SMS-04 field 4: the chosen SIM; `nil` = the phone's default.
    @Published public var subId: Int32?

    public let threadId: Int64
    let pairId: String
    let engine: SmsEngine
    let store: SmsStore
    var limit = SmsStore.pageSize
    var observation: Task<Void, Never>?

    init(threadId: Int64, pairId: String, engine: SmsEngine, store: SmsStore) {
        self.threadId = threadId
        self.pairId = pairId
        self.engine = engine
        self.store = store
        subId = engine.defaultSubId
        observe()
    }

    deinit {
        observation?.cancel()
    }

    /// The send button is usable: text within the limits, SMS active with sending allowed (fields 2, 5), not a group.
    public var canSend: Bool {
        SmsEngine.validText(draft) != nil && engine.canSend && !(thread?.isGroup ?? false)
    }

    /// The SIM picker is shown only with more than one SIM (field 4).
    public var sims: [SimInfo] { engine.sims.count > 1 ? engine.sims : [] }

    /// The user reached the oldest loaded message: the next local page, or older messages from the phone (steps 6–9).
    public func reachedTop() {
        if messages.count >= limit {
            limit += SmsStore.pageSize
            observe()
        } else if engine.mayHaveOlder(threadId: threadId) {
            engine.loadOlder(threadId: threadId)
        } else {
            historyState = .complete
        }
    }

    /// Step 1–3 of SMS-04: the draft goes into the outbox and shows as a placeholder right away.
    public func send() async {
        guard let thread, canSend else { return }
        let text = draft
        draft = ""
        if (try? await engine.reply(text: text, in: thread, subId: subId)) == nil { draft = text }
    }

    /// A1: "Try Again" on a failed message.
    public func retry(localId: String) async {
        _ = try? await engine.retry(localId: localId)
    }

    /// Re-reads after "Try Again" of E4 (history).
    public func retryHistory() {
        engine.loadOlder(threadId: threadId)
    }

    private func observe() {
        observation?.cancel()
        let pairId = pairId
        let threadId = threadId
        let limit = limit
        let pool = store.database.pool
        let region = ValueObservation.tracking { db -> ConversationSnapshot in
            ConversationSnapshot(
                thread: try SmsStore.thread(db, pairId: pairId, threadId: threadId),
                messages: try SmsStore.messages(db, pairId: pairId, threadId: threadId, limit: limit).reversed(),
                placeholders: try SmsStore.placeholders(db, pairId: pairId, threadId: threadId))
        }
        observation = Task { [weak self] in
            do {
                for try await snapshot in region.values(in: pool) {
                    self?.thread = snapshot.thread
                    self?.messages = snapshot.messages
                    self?.placeholders = snapshot.placeholders
                }
            } catch {
                self?.historyState = .failed // SMS-03 E6
            }
        }
    }
}

/// What one observation of the conversation reads in a single transaction.
struct ConversationSnapshot: Sendable {
    let thread: SmsThread?
    let messages: [SmsMessage]
    let placeholders: [SmsOutboxEntry]
}
