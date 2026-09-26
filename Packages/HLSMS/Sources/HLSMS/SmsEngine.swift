import Foundation
import HLProtocol
import HLTransport

/// SMS with the phone on the Mac and the iPhone/iPad (SMS-01…05): syncs history into the encrypted database, applies
/// new messages, statuses and read changes, loads older messages, and sends through the outbox with retries. Lists come
/// from the database; the engine reports notifications, the badge and banners through `onEvent`. It never logs content.
@MainActor
public final class SmsEngine {
    /// The phone while a session is up.
    struct Phone {
        let peer: any SmsPeer
        var feature: SmsFeature?
        var permissionsMissing: [String]
    }

    public var onEvent: (SmsEvent) -> Void = { _ in }
    /// `feature.sms` of this device (SET-02 field 7).
    public var enabledHere: () -> Bool = { true }
    /// `sms.notify` (field 8).
    public var notifyEnabled: () -> Bool = { true }
    /// The conversation open in the window in use: no notification for it (SMS-02 step 7).
    public var openThreadId: Int64?

    let store: SmsStore
    let now: () -> Int64
    var requestTimeout: Duration = .seconds(10)
    /// `SMS_OUTBOX_RETRY`: waits before the second, third and fourth try of `sms/send` without an `ack`.
    var retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(45)]
    /// E6: a provider error is retried once after this delay.
    var providerRetryDelay: Duration = .seconds(5)

    public private(set) var pairId: String?
    var phone: Phone?
    public private(set) var syncStatus = SmsSyncStatus.idle
    var syncTask: Task<Void, Never>?
    var flushTask: Task<Void, Never>?
    /// A message was queued while the flush ran: look at the queue once more.
    var flushRequested = false
    /// Messages that got no `ack` after every retry of this session: they wait for the next session (E1).
    var unanswered: Set<String> = []
    /// `features.sms` of the phone's last capability, kept while it is offline.
    var knownFeature: SmsFeature?
    /// Envelope `id` of each message's first try, reused by its retries while the app runs (API 1 logic 7).
    var envelopeIds: [String: String] = [:]
    var historyLoading: Set<Int64> = []
    /// "No more messages", kept in memory until the app restarts or a full resync (SMS-03 API 1 logic 6).
    var historyComplete: Set<Int64> = []
    /// Conversations whose older messages were asked for without a session (E2): loaded on reconnection.
    var historyWanted: Set<Int64> = []

    public init(store: SmsStore, now: @escaping () -> Int64 = { HLUUID.currentTimeMs() }) {
        self.store = store
        self.now = now
    }

    // MARK: - Pair and session

    /// The active pair changed (or was removed): state of the old pair is dropped. `capability` is the phone's last
    /// stored one (`features_json`): the SIMs and the default SIM while the phone is offline.
    public func setPair(_ pairId: String?, capability: CapabilityData? = nil) {
        knownFeature = capability?.features.sms
        guard pairId != self.pairId else { return }
        disconnected()
        self.pairId = pairId
        historyComplete.removeAll()
        historyWanted.removeAll()
        Task { await self.publishBadge() }
    }

    /// A session reached `Connected` (CONN-01 step 10, CONN-02 step 10): resend the waiting messages, then catch up.
    public func connected(peer: any SmsPeer, capability: CapabilityData) {
        phone = Phone(peer: peer, feature: capability.features.sms, permissionsMissing: capability.permissionsMissing ?? [])
        knownFeature = capability.features.sms
        unanswered.removeAll()
        guard isActive else {
            setSyncStatus(inactiveStatus)
            return
        }
        startFlush()
        startSync()
        for threadId in historyWanted { loadOlder(threadId: threadId) }
        historyWanted.removeAll()
    }

    /// `capability/update`: SMS may become active or inactive (SET-02 API 1 logic 4–5).
    public func capabilityUpdated(_ capability: CapabilityData) {
        guard phone != nil else { return }
        let wasActive = isActive
        phone?.feature = capability.features.sms
        knownFeature = capability.features.sms
        phone?.permissionsMissing = capability.permissionsMissing ?? []
        if isActive && !wasActive {
            startFlush()
            startSync()
        } else if !isActive {
            syncTask?.cancel() // stops after the page being written
            setSyncStatus(inactiveStatus)
        }
    }

    public func disconnected() {
        phone = nil
        syncTask?.cancel()
        syncTask = nil
        flushTask?.cancel()
        flushTask = nil
        if case .syncing = syncStatus { setSyncStatus(.failed(.interrupted)) }
    }

    /// SMS is active for the pair: on here, on the phone, and the phone may read SMS (SMS-01 step 2).
    public var isActive: Bool {
        guard let phone, enabledHere(), phone.feature?.enabled == true else { return false }
        return !phone.permissionsMissing.contains { $0 == Self.readSmsPermission || $0 == Self.readSmsPermissionFull }
    }

    /// The phone can send (`features.sms.can_send`, SMS-04 precondition 1).
    public var canSend: Bool {
        isActive && phone?.feature?.canSend != false
    }

    /// Active SIMs of the phone for the SIM picker (SMS-04 field 4), from the last capability.
    public var sims: [SimInfo] { knownFeature?.sims ?? [] }
    public var defaultSubId: Int32? { knownFeature?.defaultSubId }

    static let readSmsPermission = "READ_SMS"
    static let readSmsPermissionFull = "android.permission.READ_SMS"

    var inactiveStatus: SmsSyncStatus {
        guard let phone, enabledHere(), phone.feature?.enabled == true else { return .failed(.featureOff) }
        return .failed(.permissionMissing)
    }

    // MARK: - Incoming envelopes

    /// `sms/new`, `sms/status`, `sms/read_changed` from the phone.
    public func receive(_ envelope: IncomingEnvelope) {
        guard envelope.type == .sms, case .json(let payload) = envelope.body, pairId != nil else { return }
        Task {
            switch SmsOp(rawValue: payload.op) {
            case .new?: if let data = try? payload.decodeData(as: SmsNewData.self) { await self.applyNew(data) }
            case .status?: if let data = try? payload.decodeData(as: SmsStatusData.self) { await self.applyStatus(data) }
            case .readChanged?:
                if let data = try? payload.decodeData(as: SmsReadState.self) { await self.applyReadChanged(data) }
            default: break
            }
        }
    }

    func setSyncStatus(_ status: SmsSyncStatus) {
        guard status != syncStatus else { return }
        syncStatus = status
        onEvent(.syncStatus(status))
    }

    func publishBadge() async {
        guard let pairId else { return onEvent(.badge(0)) }
        if let count = try? await store.unreadThreadCount(pairId: pairId) { onEvent(.badge(count)) }
    }
}
