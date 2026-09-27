import Foundation
import HLProtocol

/// Who is on the line, as the panel, the notifications and VoiceOver name them (CALL-01 fields 2–3, CALL-03 field 1,
/// CALL-04 field 2). The screens turn it into text; this type carries no wording.
public enum CallerIdentity: Equatable, Sendable {
    /// The contact name (`display_name`).
    case name(String)
    /// The number, shown in national format.
    case number(String)
    /// `presentation = restricted`, or a call log entry without a number: "No Caller ID".
    case noCallerId
    /// No number for any other reason (`presentation = unknown`, `READ_CALL_LOG` missing): "Unknown Caller".
    case unknownCaller
    /// An outgoing call started on the phone, whose number is known only once the call log has it (CALL-03 E8).
    case outgoingCall

    /// The caller of a call context (CALL-01 fields 2–3).
    public init(state: CallStateData) {
        if let name = state.displayName, !name.isEmpty {
            self = .name(name)
        } else if let number = state.number, !number.isEmpty {
            self = .number(number)
        } else if state.direction == .outgoing {
            self = .outgoingCall
        } else if state.presentation == .restricted {
            self = .noCallerId
        } else {
            self = .unknownCaller
        }
    }

    /// The caller of a call log entry: without a number it is "No Caller ID" (CALL-04 field 2).
    public init(entry: CallLogEntryData) {
        if let name = entry.displayName, !name.isEmpty {
            self = .name(name)
        } else if let number = entry.number, !number.isEmpty {
            self = .number(number)
        } else {
            self = .noCallerId
        }
    }

    /// The waiting caller of a call with a call waiting (CALL-01 field 5): "Unknown Caller" when both are `null`.
    public static func waiting(of state: CallStateData) -> CallerIdentity? {
        guard state.waiting else { return nil }
        if let name = state.waitingDisplayName, !name.isEmpty { return .name(name) }
        if let number = state.waitingNumber, !number.isEmpty { return .number(number) }
        return .unknownCaller
    }
}

/// What the client shows for the call (CALL-01 step 12, CALL-03 fields 3).
public enum CallPhase: Equatable, Sendable {
    /// The phone rings and nothing else is going on: the incoming-call panel.
    case ringing
    /// A second call rings during a call (`waiting = true`): information only over WebSocket (E9).
    case waiting
    /// `offhook`: the in-call panel with its timer.
    case inCall
    /// `idle`: "Call ended · mm:ss" for 2 s after a call that was in progress.
    case ended
}

/// A command the user gave from the panel, a menu or a notification (CALL-02 field 9: the buttons are locked meanwhile).
public enum CallCommand: Equatable, Sendable {
    /// "Answer": `audio` is where the user takes the call (`phone` until call audio exists, Phase 4).
    case answer(CallAudioLocation)
    /// "Decline", or "Decline with Message…" when `reply` holds the text (never logged).
    case reject(reply: String?)
    /// "End" (CALL-03).
    case end

    var action: CallAction {
        switch self {
        case .answer: .answer
        case .reject: .reject
        case .end: .end
        }
    }
}

/// The call the phone reports, as this device shows it: the latest `call_event/state` with the envelope that carried
/// it, and what the user did here (Ignore, a command in progress, the last problem).
public struct ActiveCall: Equatable, Sendable {
    public let pairId: String
    public internal(set) var state: CallStateData
    /// `ts` of the envelope that carried `state` (Android clock): orders versions (CALL-01 API 1 logic 6) and anchors
    /// the timer.
    public internal(set) var envelopeTs: Int64
    /// This device's clock when `state` arrived.
    public internal(set) var receivedAtMs: Int64
    /// "Ignore": no panel and no ringing here; the call stays in the menu bar menu (CALL-01 field 9).
    public internal(set) var ignored = false
    /// A command waiting for its `ack` or for the next `state`: the buttons are locked.
    public internal(set) var command: CallCommand?
    /// Why the last command did not work, shown in the panel (CALL-02 field 10, CALL-03 field 12).
    public internal(set) var problem: CallProblem?
    /// The session to the phone is gone while the call goes on (CALL-03 E6).
    public internal(set) var connectionLost = false

    public var callId: String { state.callId }

    public var phase: CallPhase {
        switch state.state {
        case .ringing: state.waiting ? .waiting : .ringing
        case .offhook: .inCall
        case .idle: .ended
        case .unrecognized: state.answeredAt == nil ? .ringing : .inCall
        }
    }

    public var caller: CallerIdentity { CallerIdentity(state: state) }
    public var waitingCaller: CallerIdentity? { CallerIdentity.waiting(of: state) }

    /// Seconds of the timer at `nowMs` (CALL-03 special requirements): `(envelope ts − answered_at)` plus the time since
    /// the envelope arrived here, so the two clocks never need to agree; from `started_at` when never answered.
    public func elapsedSeconds(nowMs: Int64) -> Int {
        let start = state.answeredAt ?? state.startedAt
        if state.state == .idle, let ended = state.endedAt { return max(0, Int((ended - start) / 1000)) }
        return max(0, Int((envelopeTs - start + max(0, nowMs - receivedAtMs)) / 1000))
    }
}

/// A missed call to report (CALL-04 API 4): from `call_event/log_new` when the phone has `READ_CALL_LOG`, from an
/// `idle` state with `end_reason = missed` otherwise (flow A, where there is no `entry_id`).
public struct MissedCall: Equatable, Sendable {
    public let pairId: String
    public let entryId: Int64?
    public let callId: String?
    public let number: String?
    public let caller: CallerIdentity
    /// When the call started.
    public let ts: Int64
    public let subId: Int32?
    /// Only when the phone has more than one SIM.
    public let simLabel: String?

    public init(pairId: String, entryId: Int64?, callId: String?, number: String?, caller: CallerIdentity, ts: Int64,
                subId: Int32?, simLabel: String?) {
        self.pairId = pairId
        self.entryId = entryId
        self.callId = callId
        self.number = number
        self.caller = caller
        self.ts = ts
        self.subId = subId
        self.simLabel = simLabel
    }
}
