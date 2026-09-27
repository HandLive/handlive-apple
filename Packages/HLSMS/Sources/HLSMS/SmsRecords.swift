import Foundation
import GRDB
import HLProtocol

/// A row of `sms_thread` (0.9.3) as the conversation list shows it (SMS-03 fields 1–5).
public struct SmsThread: Codable, FetchableRecord, Equatable, Sendable, Identifiable {
    public var pairId: String
    public var threadId: Int64
    public var addressesJSON: String
    public var displayName: String?
    public var snippet: String?
    public var lastTs: Int64
    public var unreadCount: Int32
    public var localReadTs: Int64

    public var id: Int64 { threadId }

    /// The conversation's addresses (E.164 or as the phone has them).
    public var addresses: [String] {
        (try? HLJSON.decode([String].self, from: Data(addressesJSON.utf8))) ?? []
    }

    /// Shown as unread: unread on the phone and not read here since the last message (SMS-05 rule).
    public var isUnread: Bool {
        unreadCount > 0 && localReadTs < lastTs
    }

    /// v1 replies only to conversations with one address (SMS-04 E9).
    public var isGroup: Bool {
        addresses.count > 1
    }

    enum CodingKeys: String, CodingKey {
        case snippet
        case pairId = "pair_id"
        case threadId = "thread_id"
        case addressesJSON = "addresses_json"
        case displayName = "display_name"
        case lastTs = "last_ts"
        case unreadCount = "unread_count"
        case localReadTs = "local_read_ts"
    }
}

/// Send status of a message written on this device (SMS-04 field 7), moving only forward (API 2 logic 2).
public enum SmsSendState: String, Codable, Sendable, Comparable, CaseIterable {
    case pending, sending, sent, delivered, failed

    /// Whether `next` may follow this state: `pending` → `sending` → `sent` → `delivered`; `pending`/`sending` →
    /// `failed`. Repeated and backward updates are ignored.
    public func allows(_ next: SmsSendState) -> Bool {
        switch next {
        case .pending: false
        case .sending: self == .pending
        case .sent: self == .pending || self == .sending
        case .delivered: self == .pending || self == .sending || self == .sent
        case .failed: self == .pending || self == .sending
        }
    }

    private var order: Int {
        switch self {
        case .pending: 0
        case .sending: 1
        case .sent: 2
        case .delivered: 3
        case .failed: 4
        }
    }

    public static func < (lhs: SmsSendState, rhs: SmsSendState) -> Bool {
        lhs.order < rhs.order
    }
}

/// A message bubble (SMS-03 field 6–9): a row of `sms_message` with the send status of a message written here.
public struct SmsMessage: Codable, FetchableRecord, Equatable, Sendable, Identifiable {
    public var messageKey: String
    public var threadId: Int64
    public var address: String
    public var body: String
    public var box: String
    public var ts: Int64
    public var tsSent: Int64?
    public var read: Bool
    public var subId: Int32?
    public var localId: String?
    public var sendState: SmsSendState?

    public var id: String { messageKey }

    /// Received messages sit on the left, everything sent on the right.
    public var isIncoming: Bool {
        box == SmsBox.inbox.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case address, body, box, ts, read
        case messageKey = "message_key"
        case threadId = "thread_id"
        case tsSent = "ts_sent"
        case subId = "sub_id"
        case localId = "local_id"
        case sendState = "send_state"
    }
}

/// A row of `sms_outbox`: a message written on this device, shown as a placeholder bubble until the phone's copy
/// arrives (SMS-04 fields 6–9).
public struct SmsOutboxEntry: Codable, FetchableRecord, Equatable, Sendable, Identifiable {
    public var localId: String
    public var pairId: String
    public var threadId: Int64?
    public var addressesJSON: String
    public var body: String
    public var subId: Int32?
    public var state: SmsSendState
    public var attempts: Int
    public var lastError: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public var id: String { localId }

    public var addresses: [String] {
        (try? HLJSON.decode([String].self, from: Data(addressesJSON.utf8))) ?? []
    }

    /// `last_error` as a code of 0.8.1 (`NOT_CONNECTED` after 24 h waiting).
    public var errorCode: ErrorCode? {
        lastError.map { ErrorCode(rawValue: $0) ?? .unrecognized }
    }

    enum CodingKeys: String, CodingKey {
        case body, state, attempts
        case localId = "local_id"
        case pairId = "pair_id"
        case threadId = "thread_id"
        case addressesJSON = "addresses_json"
        case subId = "sub_id"
        case lastError = "last_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Canonical `addresses_json` (the same text for the same list, so the fallback match of SMS-04 API 4 compares it).
enum AddressList {
    static func json(_ addresses: [String]) -> String {
        (try? HLJSON.encode(addresses)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
    }
}
