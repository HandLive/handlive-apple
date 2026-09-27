// `data` of `sms/send`, its `ack`, and `sms/status` (SMS-04 API 1–2), plus `ping/ping` (CONN-02 API 2).

/// `sms/send` request: `addresses` has exactly one element in v1; no `sub_id` → the phone's default SMS SIM.
public struct SmsSendRequest: Codable, Equatable, Sendable {
    /// `SMS_BODY_MAX` (0.10), in characters.
    public static let maxBodyCharacters = 1600

    public let localId: String
    public let threadId: Int64?
    public let addresses: [String]
    public let body: String
    public let subId: Int32?

    public init(localId: String, threadId: Int64?, addresses: [String], body: String, subId: Int32?) {
        self.localId = localId
        self.threadId = threadId
        self.addresses = addresses
        self.body = body
        self.subId = subId
    }

    enum CodingKeys: String, CodingKey {
        case addresses, body
        case localId = "local_id"
        case threadId = "thread_id"
        case subId = "sub_id"
    }
}

/// `ack.data` of `sms/send`: sent as soon as the checks pass, before the radio sends (API 1 logic 1).
public struct SmsSendAckData: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let parts: Int32

    public init(accepted: Bool, parts: Int32) {
        self.accepted = accepted
        self.parts = parts
    }
}

/// `sms/status` (SMS-04 API 2): progress of a message sent from this device.
public struct SmsStatusData: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, LenientStringEnum {
        case sending, sent, delivered, failed
        case unrecognized = ""
    }

    public let localId: String
    public let messageKey: String?
    public let status: Status
    /// Present with `failed`: `SMS_NO_SERVICE`, `SMS_RADIO_OFF`, `SMS_LIMIT_EXCEEDED` or `SMS_GENERIC_FAILURE`.
    public let errorCode: ErrorCode?

    public init(localId: String, messageKey: String? = nil, status: Status, errorCode: ErrorCode? = nil) {
        self.localId = localId
        self.messageKey = messageKey
        self.status = status
        self.errorCode = errorCode
    }

    enum CodingKeys: String, CodingKey {
        case status
        case localId = "local_id"
        case messageKey = "message_key"
        case errorCode = "error_code"
    }
}

/// `ping/ping` request and its `ack` data (CONN-02 API 2): the end-to-end check over the relay.
public struct PingData: Codable, Equatable, Sendable {
    public let seq: Int64

    public init(seq: Int64) {
        self.seq = seq
    }
}

public struct PingAckData: Codable, Equatable, Sendable {
    public let seq: Int64
    public let serverTs: Int64?

    public init(seq: Int64, serverTs: Int64?) {
        self.seq = seq
        self.serverTs = serverTs
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case serverTs = "server_ts"
    }
}
