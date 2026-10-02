// `data` of `call_event/app_call` (06-call-control.md: CALL-05): a call of another app (Telegram, …) that rings on the
// phone, seen through the phone's call notifications. The answer, decline and end commands reuse `call_event/action`
// (CallMessages.swift) keyed by this `call_id`.

/// `state` of an app call: `ended` is sent once, then the phone forgets the call.
public enum AppCallState: String, Codable, Sendable, LenientStringEnum {
    case ringing, ongoing, ended
    case unrecognized = ""
}

/// `answer_mode`: `direct` when the phone can start the app's answer itself, `tap` when the user has to tap a HandLive
/// notification on the phone after Answer.
public enum AppCallAnswerMode: String, Codable, Sendable, LenientStringEnum {
    case direct, tap
    case unrecognized = ""
}

/// `audio` of an app call: the call audio stays on the phone (`mac` is reserved for later).
public enum AppCallAudio: String, Codable, Sendable, LenientStringEnum {
    case phone
    case unrecognized = ""
}

/// `end_reason` of an `ended` app call.
public enum AppCallEndReason: String, Codable, Sendable, LenientStringEnum {
    case declined, ended, missed, unknown
    case unrecognized = ""
}

/// `app`: the calling app on the phone. `label` is for display only.
public struct AppCallApp: Codable, Equatable, Sendable {
    public let package: String
    public let label: String

    public init(package: String, label: String) {
        self.package = package
        self.label = label
    }
}

/// `controls`: what the Mac may do now, computed by the phone from the app's notification.
public struct AppCallControls: Codable, Equatable, Sendable {
    public let answer: Bool
    public let decline: Bool
    public let end: Bool

    public init(answer: Bool = false, decline: Bool = false, end: Bool = false) {
        self.answer = answer
        self.decline = decline
        self.end = end
    }

    /// Nothing is allowed (an ended call).
    public static let none = AppCallControls()
}

/// `call_event/app_call` (CALL-05): the latest version of one app call, sent on every change; the newest version per
/// `call_id` wins. `caller` is personal data: it is never logged and never stored.
public struct AppCallData: Codable, Equatable, Sendable {
    public let callId: String
    public let app: AppCallApp
    public let caller: String?
    public let state: AppCallState
    public let controls: AppCallControls
    public let answerMode: AppCallAnswerMode
    public let audio: AppCallAudio
    /// Android clock, when the phone created the context.
    public let startedAt: Int64
    public let answeredAt: Int64?
    public let endedAt: Int64?
    public let endReason: AppCallEndReason?

    public init(callId: String, app: AppCallApp, caller: String?, state: AppCallState, controls: AppCallControls,
                answerMode: AppCallAnswerMode = .direct, audio: AppCallAudio = .phone, startedAt: Int64,
                answeredAt: Int64? = nil, endedAt: Int64? = nil, endReason: AppCallEndReason? = nil) {
        self.callId = callId
        self.app = app
        self.caller = caller
        self.state = state
        self.controls = controls
        self.answerMode = answerMode
        self.audio = audio
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.endedAt = endedAt
        self.endReason = endReason
    }

    enum CodingKeys: String, CodingKey {
        case app, caller, state, controls, audio
        case callId = "call_id"
        case answerMode = "answer_mode"
        case startedAt = "started_at"
        case answeredAt = "answered_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
    }

    /// Every field is required: the nullable ones are written as `null`, never left out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callId, forKey: .callId)
        try container.encode(app, forKey: .app)
        try container.encode(caller, forKey: .caller)
        try container.encode(state, forKey: .state)
        try container.encode(controls, forKey: .controls)
        try container.encode(answerMode, forKey: .answerMode)
        try container.encode(audio, forKey: .audio)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(answeredAt, forKey: .answeredAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(endReason, forKey: .endReason)
    }
}
