// `data` of the call log ops `call_event/log_sync` (with its ack) and `call_event/log_new` (06-call-control.md CALL-04
// API 1–2), and their shared `entry` object.

/// `type` of a call log entry, from the phone's `CallLog.Calls.TYPE` (the `call_log_entry.type` values of 0.9.3).
public enum CallLogType: String, Codable, Sendable, LenientStringEnum {
    case incoming, outgoing, missed, rejected, blocked, voicemail
    case unrecognized = ""
}

/// The shared `entry` object of CALL-04 (API 1 and 2).
public struct CallLogEntryData: Codable, Equatable, Sendable {
    /// `CallLog.Calls._ID` (0.2).
    public let entryId: Int64
    /// `null` when withheld or unknown.
    public let number: String?
    public let displayName: String?
    public let type: CallLogType
    /// When the call started (the `DATE` column).
    public let ts: Int64
    public let durationS: Int32
    public let subId: Int32?

    public init(entryId: Int64, number: String?, displayName: String?, type: CallLogType, ts: Int64, durationS: Int32,
                subId: Int32?) {
        self.entryId = entryId
        self.number = number
        self.displayName = displayName
        self.type = type
        self.ts = ts
        self.durationS = durationS
        self.subId = subId
    }

    enum CodingKeys: String, CodingKey {
        case number, type, ts
        case entryId = "entry_id"
        case displayName = "display_name"
        case durationS = "duration_s"
        case subId = "sub_id"
    }

    /// Every field is required: `number`, `display_name` and `sub_id` are written as `null`, never left out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryId, forKey: .entryId)
        try container.encode(number, forKey: .number)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(type, forKey: .type)
        try container.encode(ts, forKey: .ts)
        try container.encode(durationS, forKey: .durationS)
        try container.encode(subId, forKey: .subId)
    }
}

/// `call_event/log_sync` request (CALL-04 API 1): no `cursor` on the first sync; the client asks for 200 entries.
public struct CallLogSyncRequest: Codable, Equatable, Sendable {
    /// The page size the client asks for (API 1: "the client sends 200").
    public static let defaultLimit: Int32 = 200

    public let cursor: String?
    public let limit: Int32

    public init(cursor: String?, limit: Int32 = defaultLimit) {
        self.cursor = cursor
        self.limit = limit
    }
}

/// `ack.data` of `call_event/log_sync`: one page in ascending `entry_id` order, the cursor after it, whether more
/// follow, and `reset` when the phone ignored the cursor and started over (E5).
public struct CallLogSyncAckData: Codable, Equatable, Sendable {
    public let entries: [CallLogEntryData]
    public let cursor: String
    public let hasMore: Bool
    public let reset: Bool

    public init(entries: [CallLogEntryData], cursor: String, hasMore: Bool, reset: Bool) {
        self.entries = entries
        self.cursor = cursor
        self.hasMore = hasMore
        self.reset = reset
    }

    enum CodingKeys: String, CodingKey {
        case entries, cursor, reset
        case hasMore = "has_more"
    }
}

/// `call_event/log_new` (CALL-04 API 2): a new call log entry and the call context it matched, if any. Also the
/// plaintext of the `call_missed` push when the phone has `READ_CALL_LOG` (API 5).
public struct CallLogNewData: Codable, Equatable, Sendable {
    public let entry: CallLogEntryData
    public let callId: String?

    public init(entry: CallLogEntryData, callId: String?) {
        self.entry = entry
        self.callId = callId
    }

    enum CodingKeys: String, CodingKey {
        case entry
        case callId = "call_id"
    }

    /// `call_id` is required and nullable: written as `null` rather than left out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entry, forKey: .entry)
        try container.encode(callId, forKey: .callId)
    }
}
