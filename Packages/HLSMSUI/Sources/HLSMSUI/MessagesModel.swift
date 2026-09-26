import Foundation
import GRDB
import HLProtocol
import HLSMS

/// State of the Messages screens (SMS-01…05) for one pair: the conversation list read from the encrypted database and
/// kept current by GRDB observation (SMS-03 step 2), the sync banner, the badge, and the conversation being viewed.
@MainActor
public final class MessagesModel: ObservableObject {
    @Published public private(set) var threads: [SmsThread] = []
    @Published public private(set) var syncStatus = SmsSyncStatus.idle
    /// Conversations shown as unread (SMS-05 field 4): the Mac menu bar and the iOS tab badge.
    @Published public private(set) var unreadThreads = 0
    /// The selected conversation (sidebar, iPad) or `nil`.
    @Published public var selection: Int64? {
        didSet { if selection != oldValue { selectionChanged(from: oldValue) } }
    }
    /// "New Message" is open (SMS-04, ⌘N).
    @Published public var composingNew = false
    @Published public var searchText = ""
    /// iOS: "All / Unread".
    @Published public var unreadOnly = false
    /// Latest failed send per conversation, for the row's "Not sent" (ThreadRow README).
    @Published public private(set) var failedThreads: Set<Int64> = []

    public let engine: SmsEngine
    public let store: SmsStore
    public private(set) var pairId: String?
    /// The phone's name for texts such as the resync confirmation.
    public var phoneName = ""
    var listLimit = SmsStore.pageSize
    var observation: Task<Void, Never>?
    var failureObservation: Task<Void, Never>?
    var conversations: [Int64: ConversationModel] = [:]

    public init(engine: SmsEngine, store: SmsStore) {
        self.engine = engine
        self.store = store
    }

    /// The active pair (or none): the list follows its rows.
    public func setPair(_ pairId: String?) {
        guard pairId != self.pairId else { return }
        self.pairId = pairId
        selection = nil
        conversations.removeAll()
        threads = []
        listLimit = SmsStore.pageSize
        observe()
    }

    /// Engine events the screens show; the app forwards them here and to its notifier.
    public func apply(_ event: SmsEvent) {
        switch event {
        case .syncStatus(let status): syncStatus = status
        case .badge(let count): unreadThreads = count
        case .history(let threadId, let state): conversations[threadId]?.historyState = state
        default: break
        }
    }

    /// The list shown: unread filter and search over names, numbers and excerpts.
    public var visibleThreads: [SmsThread] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return threads.filter { thread in
            (!unreadOnly || thread.isUnread) && (query.isEmpty
                || (thread.displayName ?? "").lowercased().contains(query)
                || thread.addresses.contains { $0.contains(query) }
                || (thread.snippet ?? "").lowercased().contains(query))
        }
    }

    /// The next 50 conversations when the list scrolls to its end (SMS-03 field 1).
    public func loadMoreThreads() {
        guard threads.count >= listLimit else { return }
        listLimit += SmsStore.pageSize
        observe()
    }

    /// The model of one conversation, kept while it is on screen.
    public func conversation(_ threadId: Int64) -> ConversationModel {
        if let existing = conversations[threadId] { return existing }
        let model = ConversationModel(threadId: threadId, pairId: pairId ?? "", engine: engine, store: store)
        conversations[threadId] = model
        return model
    }

    /// The thread to show after a message to a new number created it (SMS-04 step 11).
    public func openThread(for address: String) async {
        guard let pairId, let thread = try? await store.pool.read({ db in
            try SmsStore.thread(db, pairId: pairId, address: address)
        }) else { return }
        composingNew = false
        selection = thread.threadId
    }

    private func observe() {
        observation?.cancel()
        failureObservation?.cancel()
        guard let pairId else { return }
        let limit = listLimit
        let pool = store.database.pool
        observation = Task { [weak self] in
            let threads = ValueObservation.tracking { db in try SmsStore.threads(db, pairId: pairId, limit: limit) }
            do {
                for try await list in threads.values(in: pool) { self?.threads = list }
            } catch {
                self?.syncStatus = .failed(.storage) // SMS-03 E6: the database could not be read
            }
        }
        failureObservation = Task { [weak self] in
            let failures = ValueObservation.tracking { db in
                try Int64.fetchAll(db, sql: "SELECT DISTINCT thread_id FROM sms_outbox WHERE pair_id = ? "
                                       + "AND state = 'failed' AND thread_id IS NOT NULL", arguments: [pairId])
            }
            do {
                for try await ids in failures.values(in: pool) { self?.failedThreads = Set(ids) }
            } catch {
                return
            }
        }
    }

    private func selectionChanged(from old: Int64?) {
        if let old { engine.closeConversation(threadId: old) }
        guard let selection else { return }
        Task { await engine.openConversation(threadId: selection) }
    }
}

extension SmsStore {
    /// The database pool, for observations of the screens.
    var pool: DatabasePool { database.pool }
}
