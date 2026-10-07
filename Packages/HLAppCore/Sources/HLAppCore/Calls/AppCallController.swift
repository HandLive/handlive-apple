import Combine
import Foundation
import HLProtocol
import HLTransport

/// Calls of other apps on the phone as this device shows them (CALL-05): applies each `call_event/app_call` by
/// `call_id` (the latest version wins, nothing after `ended`), keeps what the user did here (Ignore, a command in
/// progress, its problem) and sends Answer, Decline and End as `call_event/action` with the same `ack` rules as a
/// cellular call. It is a separate controller from `CallController`, so a fault in one never reaches the other. Platform
/// code shows `call` (panel, ringtone). It never logs, stores or persists caller names: a call lives only while the
/// phone reports it.
@MainActor
public final class AppCallController: ObservableObject {
    /// The call to show: the most recent ringing call, else the most recent ongoing one; `nil` when there is none.
    @Published public internal(set) var call: AppCall?

    /// `call.app_calls` ∧ `feature.call` of this device (SET-02): off → nothing is shown.
    public var enabledHere: () -> Bool = { true }

    let now: () -> Int64
    /// Times the waits below and the `ack` window of a command.
    let clock: any Clock<Duration>
    /// `REQUEST_TIMEOUT` for the `ack` of a command (0.10).
    var requestTimeout: Duration = .seconds(10)
    /// After a successful `ack`, how long the buttons stay locked waiting for the version with the result.
    var stateWait: Duration = .seconds(3)
    /// After reconnecting, the phone sends every live app call right after the capability exchange (CALL-05 API 1
    /// logic 7); a call it does not mention within this time is over.
    var reconnectGrace: Duration = .seconds(3)
    /// "Lost connection to the phone" shows only once the session has been gone this long.
    var connectionLostDelay: Duration = .seconds(3)
    /// Ended calls remembered to drop their late versions: at most this many.
    static let recentlyEndedCapacity = 32

    public private(set) var pairId: String?
    var peer: (any CallPeer)?
    /// `peer` of the bench lines: the phone's first 8 hex digits.
    var benchPeer = "00000000"
    /// `features.call.app_calls` of the phone's last capability: both sides must say `true`.
    public private(set) var phoneAppCalls = false
    /// Every live call by `call_id`; `call` is the one of them to show.
    var contexts: [String: AppCall] = [:]
    /// `call_id` → envelope `ts` of its last version: ended (or found gone) calls never come back.
    var recentlyEnded: [String: Int64] = [:]
    var stateWaitTasks: [String: Task<Void, Never>] = [:]
    var connectionLostTask: Task<Void, Never>?
    var staleTask: Task<Void, Never>?
    var connectedAtMs: Int64 = 0

    public init(now: @escaping () -> Int64 = { HLUUID.currentTimeMs() },
                clock: any Clock<Duration> = ContinuousClock()) {
        self.now = now
        self.clock = clock
    }

    /// App calls are in effect: on here and on the phone (0.7.2 `features.call.app_calls`, absent means off).
    public var appCallsInEffect: Bool {
        enabledHere() && phoneAppCalls
    }

    // MARK: - Pair and capability

    /// The active pair changed (or was removed): whatever was shown for the old one goes.
    public func setPair(_ pairId: String?, phoneDeviceId: String? = nil, capability: CapabilityData? = nil) {
        benchPeer = phoneDeviceId.map { String($0.replacingOccurrences(of: "-", with: "").prefix(8)) } ?? "00000000"
        phoneAppCalls = capability?.features.call?.appCalls == true
        guard pairId != self.pairId else { return }
        self.pairId = pairId
        peer = nil
        recentlyEnded.removeAll()
        clear()
    }

    /// `capability/update`: app calls may stop being in effect: the panel closes.
    public func capabilityUpdated(_ capability: CapabilityData) {
        phoneAppCalls = capability.features.call?.appCalls == true
        if !appCallsInEffect { clear() }
    }

    /// `call.app_calls` or `feature.call` changed here: off closes everything.
    public func settingChanged() {
        if !appCallsInEffect { clear() }
    }

    // MARK: - Incoming versions

    /// `call_event/app_call` from the phone; other `call_event` ops belong to `CallController` and the call log. Its
    /// bench line is `app_call_received`, apart from the cellular `call_state_received`, and carries no app or caller.
    public func receive(_ envelope: IncomingEnvelope) {
        guard envelope.type == .callEvent, case .json(let payload) = envelope.body,
              payload.op == CallEventOp.appCall.rawValue,
              let data = try? payload.decodeData(as: AppCallData.self) else { return }
        BenchLog.event("app_call_received", ["call": data.callId, "env": envelope.id, "peer": benchPeer,
                                             "state": data.state.rawValue])
        apply(data, envelopeTs: envelope.ts)
    }

    /// The latest version by envelope `ts` wins per `call_id`; a call that ended never comes back; a call already over
    /// when first heard of (its earlier versions were lost) shows nothing.
    public func apply(_ data: AppCallData, envelopeTs: Int64) {
        guard let pairId, appCallsInEffect, recentlyEnded[data.callId] == nil else { return }
        if let current = contexts[data.callId] {
            guard envelopeTs >= current.envelopeTs else { return }
            update(current, with: data, envelopeTs: envelopeTs)
            return
        }
        let arrived = AppCall(pairId: pairId, data: data, envelopeTs: envelopeTs, receivedAtMs: now())
        if arrived.phase == .ended {
            remember(data.callId, envelopeTs: envelopeTs)
            return
        }
        contexts[data.callId] = arrived
        publish()
    }

    private func update(_ current: AppCall, with data: AppCallData, envelopeTs: Int64) {
        var next = current
        let before = current.phase
        next.data = data
        next.envelopeTs = envelopeTs
        next.receivedAtMs = now()
        next.connectionLost = false
        next.withdrawn = [] // the phone's newest controls replace what it refused before
        if next.phase != before {
            // The result of a command arrived, or the call moved on by itself: the buttons unlock, a hidden call shows.
            next.command = nil
            next.ignored = false
            next.answerRequested = false
            next.problem = nil
            stateWaitTasks[data.callId]?.cancel()
        }
        if next.phase == .ended {
            close(callId: data.callId, envelopeTs: envelopeTs) // `ended` closes the panel at once
            return
        }
        contexts[data.callId] = next
        publish()
    }

    /// The call is over: the panel closes at once, and no later version of it is taken.
    func close(callId: String, envelopeTs: Int64) {
        remember(callId, envelopeTs: envelopeTs)
        cancelTasks(of: callId)
        contexts[callId] = nil
        publish()
    }

    func remember(_ callId: String, envelopeTs: Int64) {
        recentlyEnded[callId] = envelopeTs
        if recentlyEnded.count > Self.recentlyEndedCapacity,
           let oldest = recentlyEnded.min(by: { $0.value < $1.value })?.key {
            recentlyEnded[oldest] = nil
        }
    }

    func cancelTasks(of callId: String) {
        stateWaitTasks[callId]?.cancel()
        stateWaitTasks[callId] = nil
    }

    /// Nothing to show any more.
    func clear() {
        for task in stateWaitTasks.values { task.cancel() }
        stateWaitTasks.removeAll()
        connectionLostTask?.cancel()
        staleTask?.cancel()
        contexts.removeAll()
        publish()
    }

    /// Picks the call to show: ringing before ongoing, the newest first, and publishes it when it changed.
    func publish() {
        let shown = contexts.values.max { Order($0) < Order($1) }
        if shown != call { call = shown }
    }

    /// Sort key: the phase rank, then the start time, then the id for a stable tie.
    private struct Order: Comparable {
        let rank: Int
        let startedAt: Int64
        let callId: String

        init(_ call: AppCall) {
            switch call.phase {
            case .ringing, .waiting: rank = 3
            case .inCall: rank = 2
            case .ended: rank = 1
            }
            startedAt = call.data.startedAt
            callId = call.callId
        }

        static func < (lhs: Order, rhs: Order) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.callId < rhs.callId
        }
    }

    /// Replaces one live call (command state, problem, ignore) and publishes.
    func change(_ callId: String, _ edit: (inout AppCall) -> Void) {
        guard var current = contexts[callId] else { return }
        edit(&current)
        contexts[callId] = current
        publish()
    }
}
