// `data` of the `call_event` ops `state` and `action` (06-call-control.md: CALL-01 API 1, CALL-02 API 1,
// CALL-03 API 1). The call log ops are in CallLogMessages.swift, the op `app_call` in AppCallMessages.swift.

/// `op` names of `type = call_event` (0.7.1).
public enum CallEventOp: String, Sendable {
    case state, action
    case appCall = "app_call"
    case hfpStatus = "hfp_status"
    case logSync = "log_sync"
    case logNew = "log_new"
}

/// `direction` of a call context: `unknown` when the context was built while the phone was already `OFFHOOK` (E8).
public enum CallDirection: String, Codable, Sendable, LenientStringEnum {
    case incoming, outgoing, unknown
    case unrecognized = ""
}

/// `state`: the phone's aggregate state (`RINGING`, `OFFHOOK`, `IDLE`).
public enum CallPhoneState: String, Codable, Sendable, LenientStringEnum {
    case ringing, offhook, idle
    case unrecognized = ""
}

/// `presentation` of the number: `restricted` means the caller withholds it, `unknown` every other case without one.
public enum CallPresentation: String, Codable, Sendable, LenientStringEnum {
    case allowed, restricted, unknown
    case unrecognized = ""
}

/// `end_reason` of an `idle` context (API 1 logic 5).
public enum CallEndReason: String, Codable, Sendable, LenientStringEnum {
    case missed, rejected, ended
    case answeredElsewhere = "answered_elsewhere"
    case unrecognized = ""
}

/// `audio_on` and the `audio` of `answer`: where the call audio is (or should go).
public enum CallAudioLocation: String, Codable, Sendable, LenientStringEnum {
    case phone, mac
    case unrecognized = ""
}

/// `hold`, `dtmf`, `mute` of `controls`: `hfp` when only an HFP command from the Mac can do it (CALL-03 API 3).
public enum CallHfpControl: String, Codable, Sendable, LenientStringEnum {
    case hfp, unavailable
    case unrecognized = ""
}

/// `controls`: what the receiving client may do, computed by the phone for that client (API 1 logic 4).
public struct CallControls: Codable, Equatable, Sendable {
    public let answer: Bool
    public let reject: Bool
    public let end: Bool
    public let hold: CallHfpControl
    public let dtmf: CallHfpControl
    public let mute: CallHfpControl

    public init(answer: Bool = false, reject: Bool = false, end: Bool = false, hold: CallHfpControl = .unavailable,
                dtmf: CallHfpControl = .unavailable, mute: CallHfpControl = .unavailable) {
        self.answer = answer
        self.reject = reject
        self.end = end
        self.hold = hold
        self.dtmf = dtmf
        self.mute = mute
    }

    /// Nothing is allowed (an ended call, or controls a newer phone sends in a shape this app does not know).
    public static let none = CallControls()
}

/// `call_event/state` (CALL-01 API 1): the phone's call context, sent whenever a field changes. Also the plaintext of
/// the `call_incoming` push and of the flow A `call_missed` push (CALL-01 API 4, CALL-04 API 5). Numbers and names are
/// never logged.
public struct CallStateData: Codable, Equatable, Sendable {
    public let callId: String
    public let direction: CallDirection
    public let state: CallPhoneState
    public let waiting: Bool
    public let number: String?
    public let displayName: String?
    public let presentation: CallPresentation
    public let subId: Int32?
    /// Only when the phone has more than one active SIM.
    public let simLabel: String?
    public let waitingNumber: String?
    public let waitingDisplayName: String?
    /// Android clock.
    public let startedAt: Int64
    public let answeredAt: Int64?
    public let endedAt: Int64?
    public let endReason: CallEndReason?
    public let controls: CallControls
    public let hfpConnected: Bool
    public let audioOn: CallAudioLocation

    public init(callId: String, direction: CallDirection, state: CallPhoneState, waiting: Bool = false,
                number: String?, displayName: String?, presentation: CallPresentation, subId: Int32? = nil,
                simLabel: String? = nil, waitingNumber: String? = nil, waitingDisplayName: String? = nil,
                startedAt: Int64, answeredAt: Int64? = nil, endedAt: Int64? = nil, endReason: CallEndReason? = nil,
                controls: CallControls, hfpConnected: Bool = false, audioOn: CallAudioLocation = .phone) {
        self.callId = callId
        self.direction = direction
        self.state = state
        self.waiting = waiting
        self.number = number
        self.displayName = displayName
        self.presentation = presentation
        self.subId = subId
        self.simLabel = simLabel
        self.waitingNumber = waitingNumber
        self.waitingDisplayName = waitingDisplayName
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.controls = controls
        self.hfpConnected = hfpConnected
        self.audioOn = audioOn
    }

    enum CodingKeys: String, CodingKey {
        case direction, state, waiting, number, presentation, controls
        case callId = "call_id"
        case displayName = "display_name"
        case subId = "sub_id"
        case simLabel = "sim_label"
        case waitingNumber = "waiting_number"
        case waitingDisplayName = "waiting_display_name"
        case startedAt = "started_at"
        case answeredAt = "answered_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
        case hfpConnected = "hfp_connected"
        case audioOn = "audio_on"
    }

    /// Every field is required: the nullable ones are written as `null`, never left out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callId, forKey: .callId)
        try container.encode(direction, forKey: .direction)
        try container.encode(state, forKey: .state)
        try container.encode(waiting, forKey: .waiting)
        try container.encode(number, forKey: .number)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(subId, forKey: .subId)
        try container.encode(simLabel, forKey: .simLabel)
        try container.encode(waitingNumber, forKey: .waitingNumber)
        try container.encode(waitingDisplayName, forKey: .waitingDisplayName)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(answeredAt, forKey: .answeredAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(endReason, forKey: .endReason)
        try container.encode(controls, forKey: .controls)
        try container.encode(hfpConnected, forKey: .hfpConnected)
        try container.encode(audioOn, forKey: .audioOn)
    }
}

/// `action` of `call_event/action`. Over WebSocket the phone carries out only `answer`, `reject` and `end`; the others
/// always get `CALL_HFP_REQUIRED` (0.7.1), so this app never sends them.
public enum CallAction: String, Codable, Sendable, LenientStringEnum {
    case answer, reject, end, hold, unhold, dtmf, mute
    case unrecognized = ""
}

/// `call_event/action` (CALL-02 API 1, CALL-03 API 1). `audio` only goes with `answer`; absent means `phone`.
public struct CallActionRequest: Codable, Equatable, Sendable {
    public let callId: String
    public let action: CallAction
    public let audio: CallAudioLocation?

    public init(callId: String, action: CallAction, audio: CallAudioLocation? = nil) {
        self.callId = callId
        self.action = action
        self.audio = action == .answer ? audio : nil
    }

    enum CodingKeys: String, CodingKey {
        case action, audio
        case callId = "call_id"
    }
}

/// `details` of a `CALL_ACTION_NOT_ALLOWED` error `ack`: the phone's state and why the action was refused.
public struct CallActionNotAllowedDetails: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable, LenientStringEnum {
        /// `answer`/`reject` when not ringing, `end` when not offhook, or another command within 3 s.
        case state
        /// A waiting call is present.
        case waiting
        /// `answer` from an iPhone/iPad.
        case platform
        /// Telecom refused, for example an emergency call (CALL-03 E9).
        case system
        case unrecognized = ""
    }

    public let state: CallPhoneState
    public let reason: Reason

    public init(state: CallPhoneState, reason: Reason) {
        self.state = state
        self.reason = reason
    }
}
