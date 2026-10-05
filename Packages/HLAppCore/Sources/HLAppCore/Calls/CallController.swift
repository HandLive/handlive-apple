import Combine
import Foundation
import HLProtocol
import HLTransport

/// What the call controller tells the app besides the published call.
public enum CallEvent: Equatable, Sendable {
    /// The phone has no call log (flow A of CALL-04): this ended call was missed, so it is notified from its `state`.
    case missed(MissedCall)
    /// "Decline with Message…" went through: send `body` to `number` by SMS through the call's SIM (CALL-02 step 8).
    case sendReply(pairId: String, number: String, subId: Int32?, body: String)
}

/// The phone's call as this device shows it (CALL-01…03): applies each `call_event/state` in order (API 1 logic 6),
/// keeps what the user did here (Ignore, a command in progress, its problem), and sends Answer, Decline and End with the
/// rules of CALL-02 step 4 and E5 — one `ack` wait of `REQUEST_TIMEOUT`, the same envelope `id` again if the session
/// comes back in time, never a new `id` on its own. Platform code shows `call` (panel, banner, notification, menu). It
/// never logs numbers, names or quick replies.
@MainActor
public final class CallController: ObservableObject {
    /// The call the phone reports right now; `nil` when there is none to show.
    @Published public internal(set) var call: ActiveCall?

    public var onEvent: (CallEvent) -> Void = { _ in }
    /// `feature.call` of this device (SET-02 field 10): off → nothing is shown.
    public var enabledHere: () -> Bool = { true }

    let now: () -> Int64
    /// Times the waits below and the `ack` window of a command.
    let clock: any Clock<Duration>
    /// `REQUEST_TIMEOUT` for the `ack` of a command (0.10).
    var requestTimeout: Duration = .seconds(10)
    /// After a successful `ack`, how long the buttons stay locked waiting for the `state` with the result (step 7).
    var stateWait: Duration = .seconds(3)
    /// "Call ended · mm:ss" stays this long before the panel closes (CALL-03 postconditions).
    var endedDisplay: Duration = .seconds(2)
    /// After reconnecting, the phone sends the current state right after the capability exchange (CALL-01 E8); a call
    /// it does not mention within this time is over.
    var reconnectGrace: Duration = .seconds(3)
    /// "Lost connection to the phone" shows only once the session has been gone this long: a quick reconnect (rekey,
    /// network change) shows nothing (CALL-03 E6).
    var connectionLostDelay: Duration = .seconds(3)
    /// Ended calls remembered to drop their late versions (logic 6): at most this many.
    static let recentlyEndedCapacity = 32

    public private(set) var pairId: String?
    var peer: (any CallPeer)?
    /// `peer` of the bench lines: the phone's first 8 hex digits.
    var benchPeer = "00000000"
    /// `features.call` of the phone's last capability, and its missing permissions.
    public private(set) var phoneFeature: CallFeature?
    public private(set) var permissionsMissing: [String] = []
    var connectedAtMs: Int64 = 0
    /// `call_id` → envelope `ts` of its `idle` version.
    var recentlyEnded: [String: Int64] = [:]
    /// Decline with Message waiting for the decline to go through.
    var pendingReply: (callId: String, body: String)?
    var closeTask: Task<Void, Never>?
    var staleTask: Task<Void, Never>?
    var connectionLostTask: Task<Void, Never>?
    var stateWaitTask: Task<Void, Never>?

    public init(now: @escaping () -> Int64 = { HLUUID.currentTimeMs() },
                clock: any Clock<Duration> = ContinuousClock()) {
        self.now = now
        self.clock = clock
    }

    // MARK: - Pair and session

    /// The active pair changed (or was removed): whatever was shown for the old one goes.
    public func setPair(_ pairId: String?, phoneDeviceId: String? = nil, capability: CapabilityData? = nil) {
        benchPeer = phoneDeviceId.map { String($0.replacingOccurrences(of: "-", with: "").prefix(8)) } ?? "00000000"
        phoneFeature = capability?.features.call
        permissionsMissing = capability?.permissionsMissing ?? []
        guard pairId != self.pairId else { return }
        self.pairId = pairId
        peer = nil
        recentlyEnded.removeAll()
        clear()
    }

    /// `capability/update`: calls may stop being in effect (SET-02 API 1 logic 4: the panel and notifications close).
    public func capabilityUpdated(_ capability: CapabilityData) {
        phoneFeature = capability.features.call
        permissionsMissing = capability.permissionsMissing ?? []
        if !callsInEffect { clear() }
    }

    /// `feature.call` changed here: off closes everything (SET-02 field 10).
    public func settingChanged() {
        if !enabledHere() { clear() }
    }

    /// Calls are in effect: on here and on the phone, and the phone may read its state (CALL-01 E1).
    public var callsInEffect: Bool {
        guard enabledHere(), let phoneFeature, phoneFeature.enabled else { return false }
        return !CallPermissions.missing(CallPermissions.phoneState, in: permissionsMissing)
    }

    /// The phone reports its call log (`features.call.caller_id` and no missing `READ_CALL_LOG`): missed calls come from
    /// `log_new`; otherwise from `state` (CALL-04 API 2 logic 3, flow A).
    public var callLogAvailable: Bool {
        phoneFeature?.callerId == true && !CallPermissions.missing(CallPermissions.callLog, in: permissionsMissing)
    }

    // MARK: - Incoming states

    /// `call_event/state` from the phone; other `call_event` ops are for the call log.
    public func receive(_ envelope: IncomingEnvelope) {
        guard envelope.type == .callEvent, case .json(let payload) = envelope.body,
              payload.op == CallEventOp.state.rawValue,
              let state = try? payload.decodeData(as: CallStateData.self) else { return }
        var fields = [("call", state.callId), ("env", envelope.id), ("peer", benchPeer), ("state", state.state.rawValue)]
        if state.waiting { fields.append(("waiting", "true")) }
        BenchLog.event("call_state_received", fields: fields)
        apply(state, envelopeTs: envelope.ts)
    }

    /// CALL-01 API 1 logic 6: the latest version by envelope `ts`; an `idle` call only takes another `idle` version
    /// (the correction of logic 5); a new `call_id` replaces the old context.
    public func apply(_ state: CallStateData, envelopeTs: Int64) {
        guard let pairId, enabledHere() else { return }
        if let current = call, current.callId == state.callId {
            guard envelopeTs >= current.envelopeTs, current.state.state != .idle || state.state == .idle else { return }
            update(current, with: state, envelopeTs: envelopeTs)
            return
        }
        if let endedTs = recentlyEnded[state.callId] {
            if state.state == .idle, envelopeTs >= endedTs { recentlyEnded[state.callId] = envelopeTs }
            return
        }
        if let current = call {
            guard envelopeTs >= current.envelopeTs else { return }
            if current.state.state != .idle { remember(current.callId, envelopeTs: current.envelopeTs) }
        }
        let arrived = ActiveCall(pairId: pairId, state: state, envelopeTs: envelopeTs, receivedAtMs: now())
        clear()
        if state.state == .idle {
            // A call already over when first heard of (its earlier versions were lost): nothing to show.
            ended(arrived, wasInProgress: false)
        } else {
            call = arrived
        }
    }

    private func update(_ current: ActiveCall, with state: CallStateData, envelopeTs: Int64) {
        var next = current
        let before = current.phase
        next.state = state
        next.envelopeTs = envelopeTs
        next.receivedAtMs = now()
        next.connectionLost = false
        if next.phase != before {
            // The result of a command arrived, or the call moved on by itself: the buttons unlock.
            next.command = nil
            next.ignored = false
            stateWaitTask?.cancel()
        }
        if before != .ended, next.phase == .ended {
            ended(next, wasInProgress: before == .inCall || before == .waiting)
            return
        }
        if next.phase == .inCall, pendingReply?.callId == state.callId {
            pendingReply = nil
            next.problem = .messageNotSent // CALL-02 E9: the call was answered, the message is not sent
        }
        call = next
    }

    /// `idle`: send a pending quick reply, report a missed call of flow A, show "Call ended" for a call that was in
    /// progress, and close otherwise.
    private func ended(_ ended: ActiveCall, wasInProgress: Bool) {
        remember(ended.callId, envelopeTs: ended.envelopeTs)
        if let reply = pendingReply, reply.callId == ended.callId {
            pendingReply = nil
            sendReply(reply.body, for: ended.state)
        }
        if ended.state.endReason == .missed, !callLogAvailable {
            onEvent(.missed(MissedCall(pairId: ended.pairId, entryId: nil, callId: ended.callId,
                                       number: ended.state.number, caller: ended.caller, ts: ended.state.startedAt,
                                       subId: ended.state.subId, simLabel: ended.state.simLabel)))
        }
        guard wasInProgress else {
            if call?.callId == ended.callId { clear() }
            return
        }
        call = ended
        let callId = ended.callId
        closeTask?.cancel()
        closeTask = Task { [weak self, clock, endedDisplay] in
            try? await clock.sleep(for: endedDisplay)
            guard !Task.isCancelled, let self, self.call?.callId == callId else { return }
            self.clear()
        }
    }

    func remember(_ callId: String, envelopeTs: Int64) {
        recentlyEnded[callId] = envelopeTs
        if recentlyEnded.count > Self.recentlyEndedCapacity,
           let oldest = recentlyEnded.min(by: { $0.value < $1.value })?.key {
            recentlyEnded[oldest] = nil
        }
    }

    /// Nothing to show any more.
    func clear() {
        closeTask?.cancel()
        staleTask?.cancel()
        connectionLostTask?.cancel()
        stateWaitTask?.cancel()
        pendingReply = nil
        call = nil
    }

    func sendReply(_ body: String, for state: CallStateData) {
        guard let number = state.number, let pairId else { return }
        onEvent(.sendReply(pairId: pairId, number: number, subId: state.subId, body: body))
    }
}
