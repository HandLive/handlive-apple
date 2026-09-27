import Combine
import Foundation
import GRDB
import HLProtocol

/// The call list of one pair (CALL-04 fields 1–7, 11–12): the entries read from the encrypted database and kept current
/// by GRDB observation, the badge, the sync state and when the log last synced. While the list is on screen its missed
/// calls count as seen (step 12).
@MainActor
public final class CallsModel: ObservableObject {
    @Published public private(set) var entries: [CallLogRecord] = []
    /// Unseen missed calls (field 7): the Calls tab (iOS) and the Calls item (Mac).
    @Published public private(set) var unseenMissed = 0
    @Published public private(set) var status = CallLogStatus.idle
    /// `sync_cursor.updated_at` of the `calllog` stream (field 11).
    @Published public private(set) var lastSyncAt: Int64?

    public let engine: CallLogEngine
    public let store: CallLogStore
    public private(set) var pairId: String?
    /// The list is on screen.
    public private(set) var isVisible = false
    var listLimit = CallLogStore.pageSize
    var observation: Task<Void, Never>?

    public init(engine: CallLogEngine, store: CallLogStore) {
        self.engine = engine
        self.store = store
    }

    /// The active pair (or none): the list follows its rows.
    public func setPair(_ pairId: String?) {
        guard pairId != self.pairId else { return }
        self.pairId = pairId
        entries = []
        unseenMissed = 0
        listLimit = CallLogStore.pageSize
        lastSyncAt = nil
        observe()
        refreshLastSync()
    }

    /// Engine events the list shows; the app forwards them here and to its notifier.
    public func apply(_ event: CallLogEvent) {
        switch event {
        case .badge(let count):
            unseenMissed = count
            // A missed call that arrives while the list is on screen is seen at once.
            if count > 0, isVisible { Task { await engine.markAllSeen() } }
        case .status(let status):
            self.status = status
            if status == .done { refreshLastSync() }
        case .missed, .removeMissedNotifications:
            break
        }
    }

    /// The list came on screen or left it: on screen, every missed call of the pair is seen (step 12).
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { Task { await engine.markAllSeen() } }
    }

    /// The next 100 entries when the list scrolls to its end (field 1).
    public func loadMore() {
        guard entries.count >= listLimit else { return }
        listLimit += CallLogStore.pageSize
        observe()
    }

    /// The label of the entry's SIM when the phone has two (field 6).
    public func simLabel(subId: Int32?) -> String? {
        engine.simLabel(subId: subId)
    }

    /// Stops reading the database ("Delete All HandLive Data", before its files go).
    public func close() {
        observation?.cancel()
        observation = nil
        entries = []
    }

    private func refreshLastSync() {
        guard let pairId else { return }
        Task { [weak self, store] in
            let time = try? await store.lastSync(pairId: pairId)
            if self?.pairId == pairId { self?.lastSyncAt = time }
        }
    }

    private func observe() {
        observation?.cancel()
        guard let pairId else { return }
        let limit = listLimit
        let pool = store.pool
        observation = Task { [weak self] in
            let list = ValueObservation.tracking { db in try CallLogStore.entries(db, pairId: pairId, limit: limit) }
            do {
                for try await entries in list.values(in: pool) { self?.entries = entries }
            } catch {
                self?.status = .storage // the database could not be read
            }
        }
    }
}
