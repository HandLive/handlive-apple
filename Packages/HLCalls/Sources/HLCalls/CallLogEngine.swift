import Foundation
import HLAppCore
import HLProtocol
import HLTransport

/// State of the call log sync (Settings › Calls, the call list).
public enum CallLogStatus: Equatable, Sendable {
    case idle
    case syncing
    case done
    /// E2: the phone may not read its call log — the list shows the permission hint (field 12).
    case permissionMissing
    /// E4, E6: connection lost, no `ack`, or the phone could not read its call log twice; the next session carries on.
    case interrupted
    /// E7: the encrypted database could not be written.
    case storage
}

/// What the call log engine tells the app.
public enum CallLogEvent: Equatable, Sendable {
    /// A new missed call from `log_new` while calls notify here (CALL-04 steps 9–10).
    case missed(MissedCall)
    /// Unseen missed calls of the pair (field 7): the Calls badge.
    case badge(Int)
    case status(CallLogStatus)
    /// The pair's missed-call notifications go: all of them (list opened) or one entry's (step 12).
    case removeMissedNotifications(pairId: String, entryId: Int64?)
}

/// The phone's call log on this device (CALL-04): `log_sync` pages after every connection while the call log is in
/// effect, `log_new` while connected, the missed-call notifications from `log_new`, the badge and the seen marks. One
/// sync per pair at a time; each page and its cursor are written in one transaction. It never logs numbers or names.
@MainActor
public final class CallLogEngine {
    public var onEvent: (CallLogEvent) -> Void = { _ in }
    /// `feature.call` of this device (SET-02 field 10).
    public var enabledHere: () -> Bool = { true }
    /// `call.notify` and the notification permission (E8): the log still syncs, without notifications.
    public var notifyEnabled: () -> Bool = { true }

    let store: CallLogStore
    let now: () -> Int64
    var requestTimeout: Duration = .seconds(10)
    /// E6: a provider error is retried once after this delay.
    var providerRetryDelay: Duration = .seconds(5)

    public private(set) var pairId: String?
    public private(set) var status = CallLogStatus.idle
    var peer: (any CallPeer)?
    /// The phone's last capability, kept while it is offline (the SIM labels, whether the call log is available).
    var capability: CapabilityData?
    var syncTask: Task<Void, Never>?

    public init(store: CallLogStore, now: @escaping () -> Int64 = { HLUUID.currentTimeMs() }) {
        self.store = store
        self.now = now
    }

    // MARK: - Pair and session

    public func setPair(_ pairId: String?, capability: CapabilityData?) {
        self.capability = capability
        guard pairId != self.pairId else { return }
        disconnected()
        self.pairId = pairId
        setStatus(.idle)
        Task { await publishBadge() }
    }

    /// Step 1: a session is `Connected` and the phone's capability arrived.
    public func connected(peer: any CallPeer, capability: CapabilityData) {
        self.peer = peer
        self.capability = capability
        startSyncIfAvailable()
    }

    /// `capability/update`: the call log may come into effect (sync) or stop (SET-02 API 1 logic 4–5).
    public func capabilityUpdated(_ capability: CapabilityData) {
        let wasAvailable = callLogAvailable
        self.capability = capability
        if callLogAvailable, !wasAvailable {
            startSyncIfAvailable()
        } else if !callLogAvailable {
            syncTask?.cancel()
            syncTask = nil
            setStatus(callsInEffect ? .permissionMissing : .idle)
        }
    }

    public func disconnected() {
        peer = nil
        syncTask?.cancel()
        syncTask = nil
        if status == .syncing { setStatus(.interrupted) }
    }

    /// Calls are in effect for the pair (CALL-04 precondition 2).
    public var callsInEffect: Bool {
        guard enabledHere(), let call = capability?.features.call, call.enabled else { return false }
        return !CallPermissions.missing(CallPermissions.phoneState, in: capability?.permissionsMissing ?? [])
    }

    /// Step 2: `features.call.caller_id` and no missing `READ_CALL_LOG`.
    public var callLogAvailable: Bool {
        callsInEffect && capability?.features.call?.callerId == true
            && !CallPermissions.missing(CallPermissions.callLog, in: capability?.permissionsMissing ?? [])
    }

    /// The label of the SIM `subId` when the phone has more than one SIM (field 6).
    public func simLabel(subId: Int32?) -> String? {
        guard let subId, let sims = capability?.features.sms?.sims, sims.count > 1 else { return nil }
        return sims.first { $0.subId == subId }?.label
    }

    func startSyncIfAvailable() {
        guard let pairId, peer != nil else { return }
        guard callLogAvailable else {
            setStatus(callsInEffect ? .permissionMissing : .idle)
            return
        }
        guard syncTask == nil else { return } // one sync of the pair at a time
        syncTask = Task { [weak self] in
            await self?.sync(pairId: pairId)
            self?.syncTask = nil
        }
    }

    // MARK: - log_new

    /// `call_event/log_new` (API 2): upsert right away (also during a sync); notify a new missed call (step 9). The
    /// cursor does not move, so a `log_new` that was missed still comes with the next `log_sync`.
    public func receive(_ envelope: IncomingEnvelope) {
        guard envelope.type == .callEvent, case .json(let payload) = envelope.body,
              payload.op == CallEventOp.logNew.rawValue, let pairId,
              let new = try? payload.decodeData(as: CallLogNewData.self) else { return }
        Task { await applyNew(new, pairId: pairId) }
    }

    func applyNew(_ new: CallLogNewData, pairId: String) async {
        guard let isNew = try? await store.applyNew(new.entry, pairId: pairId) else { return } // E7
        guard pairId == self.pairId else { return }
        if isNew, new.entry.type == .missed, notifyEnabled(), enabledHere() {
            onEvent(.missed(MissedCall(pairId: pairId, entryId: new.entry.entryId, callId: new.callId,
                                       number: new.entry.number, caller: CallerIdentity(entry: new.entry),
                                       ts: new.entry.ts, subId: new.entry.subId,
                                       simLabel: simLabel(subId: new.entry.subId))))
        }
        await publishBadge()
    }

    // MARK: - Seen

    /// Step 12: the call list opened — every missed call of the pair is seen and its notifications go.
    public func markAllSeen() async {
        guard let pairId else { return }
        try? await store.markAllMissedSeen(pairId: pairId)
        onEvent(.removeMissedNotifications(pairId: pairId, entryId: nil))
        await publishBadge()
    }

    /// Step 12: one missed-call notification tapped.
    public func markSeen(entryId: Int64) async {
        guard let pairId else { return }
        try? await store.markSeen(pairId: pairId, entryId: entryId)
        onEvent(.removeMissedNotifications(pairId: pairId, entryId: entryId))
        await publishBadge()
    }

    func publishBadge() async {
        guard let pairId else { return onEvent(.badge(0)) }
        if let count = try? await store.unseenMissedCount(pairId: pairId) { onEvent(.badge(count)) }
    }

    func setStatus(_ status: CallLogStatus) {
        guard status != self.status else { return }
        self.status = status
        onEvent(.status(status))
    }
}
