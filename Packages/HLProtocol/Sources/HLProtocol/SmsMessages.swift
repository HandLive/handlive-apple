// `data` of the `sms` ops (05-sms.md: SMS-01 API 1, SMS-02 API 1, SMS-03 API 1, SMS-04 API 1–2, SMS-05 API 1).

/// `op` names of `type = sms` (0.7.1).
public enum SmsOp: String, Sendable {
    case sync, history, new, send, status
    case readChanged = "read_changed"
}

/// `box` of a message (5.1.5 `message`): the provider's `type` column; drafts are never sent.
public enum SmsBox: String, Codable, Sendable, LenientStringEnum {
    case inbox, sent, outbox, failed, queued
    case unrecognized = ""
}

/// The `thread` object shared by `sms/sync`, `sms/new` (5.1.5).
public struct SmsThreadData: Codable, Equatable, Sendable {
    public let threadId: Int64
    /// E.164 when the phone could normalize the address, otherwise as the provider has it (short codes, names).
    public let addresses: [String]
    /// Contact names joined with ", "; `null` without `READ_CONTACTS` or when not in the contacts (SMS-01 E3).
    public let displayName: String?
    public let snippet: String
    public let lastTs: Int64
    public let unreadCount: Int32

    public init(threadId: Int64, addresses: [String], displayName: String?, snippet: String, lastTs: Int64,
                unreadCount: Int32) {
        self.threadId = threadId
        self.addresses = addresses
        self.displayName = displayName
        self.snippet = snippet
        self.lastTs = lastTs
        self.unreadCount = unreadCount
    }

    enum CodingKeys: String, CodingKey {
        case addresses, snippet
        case threadId = "thread_id"
        case displayName = "display_name"
        case lastTs = "last_ts"
        case unreadCount = "unread_count"
    }

    /// `display_name` is required and nullable: it is written as `null` rather than left out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(addresses, forKey: .addresses)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(lastTs, forKey: .lastTs)
        try container.encode(unreadCount, forKey: .unreadCount)
    }
}

/// The `message` object (5.1.5). `local_id` only travels in the `sms/new` sent to the client that sent the message.
public struct SmsMessageData: Codable, Equatable, Sendable {
    public let messageKey: String
    public let threadId: Int64
    public let address: String
    public let body: String
    public let box: SmsBox
    public let ts: Int64
    public let tsSent: Int64?
    public let read: Bool
    public let subId: Int32?
    public let localId: String?

    public init(messageKey: String, threadId: Int64, address: String, body: String, box: SmsBox, ts: Int64,
                tsSent: Int64? = nil, read: Bool, subId: Int32? = nil, localId: String? = nil) {
        self.messageKey = messageKey
        self.threadId = threadId
        self.address = address
        self.body = body
        self.box = box
        self.ts = ts
        self.tsSent = tsSent
        self.read = read
        self.subId = subId
        self.localId = localId
    }

    enum CodingKeys: String, CodingKey {
        case address, body, box, ts, read
        case messageKey = "message_key"
        case threadId = "thread_id"
        case tsSent = "ts_sent"
        case subId = "sub_id"
        case localId = "local_id"
    }
}

/// `sms/sync` request (SMS-01 API 1): no `cursor` → first sync; `page_token` only while looping.
public struct SmsSyncRequest: Codable, Equatable, Sendable {
    /// `SMS_SYNC_THREADS` and `SMS_SYNC_PER_THREAD` (0.10).
    public static let defaultThreadLimit: Int32 = 200
    public static let defaultPerThreadLimit: Int32 = 50

    public let cursor: String?
    public let pageToken: String?
    public let threadLimit: Int32
    public let perThreadLimit: Int32

    public init(cursor: String?, pageToken: String? = nil, threadLimit: Int32 = defaultThreadLimit,
                perThreadLimit: Int32 = defaultPerThreadLimit) {
        self.cursor = cursor
        self.pageToken = pageToken
        self.threadLimit = threadLimit
        self.perThreadLimit = perThreadLimit
    }

    enum CodingKeys: String, CodingKey {
        case cursor
        case pageToken = "page_token"
        case threadLimit = "thread_limit"
        case perThreadLimit = "per_thread_limit"
    }
}

/// Unread state of one conversation on the phone: an entry of `unread` in the last `sms/sync` page and the data of
/// `sms/read_changed` (SMS-05 API 1). Inbox messages with `ts ≤ read_up_to_ts` are read.
public struct SmsReadState: Codable, Equatable, Sendable {
    public let threadId: Int64
    public let unreadCount: Int32
    public let readUpToTs: Int64

    public init(threadId: Int64, unreadCount: Int32, readUpToTs: Int64) {
        self.threadId = threadId
        self.unreadCount = unreadCount
        self.readUpToTs = readUpToTs
    }

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case unreadCount = "unread_count"
        case readUpToTs = "read_up_to_ts"
    }
}

/// `ack.data` of `sms/sync`: `cursor` is saved only with `has_more = false`; the last page carries `unread`.
public struct SmsSyncAckData: Codable, Equatable, Sendable {
    public let threads: [SmsThreadData]
    public let messages: [SmsMessageData]
    public let cursor: String
    public let pageToken: String?
    public let hasMore: Bool
    public let unread: [SmsReadState]?

    public init(threads: [SmsThreadData], messages: [SmsMessageData], cursor: String, pageToken: String? = nil,
                hasMore: Bool, unread: [SmsReadState]? = nil) {
        self.threads = threads
        self.messages = messages
        self.cursor = cursor
        self.pageToken = pageToken
        self.hasMore = hasMore
        self.unread = unread
    }

    enum CodingKeys: String, CodingKey {
        case threads, messages, cursor, unread
        case pageToken = "page_token"
        case hasMore = "has_more"
    }
}

/// `sms/history` request (SMS-03 API 1): messages with `date < before_ts`, newest first.
public struct SmsHistoryRequest: Codable, Equatable, Sendable {
    /// `SMS_HISTORY_PAGE` (0.10).
    public static let defaultLimit: Int32 = 50

    public let threadId: Int64
    public let beforeTs: Int64
    public let limit: Int32

    public init(threadId: Int64, beforeTs: Int64, limit: Int32 = defaultLimit) {
        self.threadId = threadId
        self.beforeTs = beforeTs
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case limit
        case threadId = "thread_id"
        case beforeTs = "before_ts"
    }
}

public struct SmsHistoryAckData: Codable, Equatable, Sendable {
    public let messages: [SmsMessageData]
    public let hasMore: Bool

    public init(messages: [SmsMessageData], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }
}

/// `sms/new` (SMS-02 API 1): the new message and the conversation summary after it.
public struct SmsNewData: Codable, Equatable, Sendable {
    public let message: SmsMessageData
    public let thread: SmsThreadData

    public init(message: SmsMessageData, thread: SmsThreadData) {
        self.message = message
        self.thread = thread
    }
}
