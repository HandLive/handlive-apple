import Foundation
import GRDB
import HLProtocol

extension SmsStore {
    /// `SMS_HISTORY_PAGE` rows per page of the list and of a conversation (SMS-03).
    public static let pageSize = 50

    /// SMS-03 step 2: the conversation list, newest first, 50 rows after the last row of the previous page.
    public static func threads(_ db: Database, pairId: String, after last: SmsThread? = nil,
                               limit: Int = pageSize) throws -> [SmsThread] {
        try SmsThread.fetchAll(db, sql: """
            SELECT * FROM sms_thread
            WHERE pair_id = ? AND (? IS NULL OR (last_ts, thread_id) < (?, ?))
            ORDER BY last_ts DESC, thread_id DESC
            LIMIT ?
            """, arguments: [pairId, last?.lastTs, last?.lastTs, last?.threadId, limit])
    }

    /// SMS-03 steps 4 and 6: a page of stored messages (keyset on `ts`, `message_key`), newest first, with the status
    /// of messages written on this device.
    public static func messages(_ db: Database, pairId: String, threadId: Int64, before last: SmsMessage? = nil,
                                limit: Int = pageSize) throws -> [SmsMessage] {
        try SmsMessage.fetchAll(db, sql: """
            SELECT m.message_key, m.thread_id, m.address, m.body, m.box, m.ts, m.ts_sent, m.read, m.sub_id,
                   m.local_id, o.state AS send_state
            FROM sms_message m
            LEFT JOIN sms_outbox o ON o.local_id = m.local_id
            WHERE m.pair_id = ? AND m.thread_id = ?
              AND (? IS NULL OR (m.ts, m.message_key) < (?, ?))
            ORDER BY m.ts DESC, m.message_key DESC
            LIMIT ?
            """, arguments: [pairId, threadId, last?.ts, last?.ts, last?.messageKey, limit])
    }

    /// SMS-03 step 4: placeholders not yet matched to a real message, oldest first. `threadId` `nil` = messages to a
    /// new number (SMS-04 step 3).
    public static func placeholders(_ db: Database, pairId: String, threadId: Int64?) throws -> [SmsOutboxEntry] {
        try SmsOutboxEntry.fetchAll(db, sql: """
            SELECT o.* FROM sms_outbox o
            WHERE o.pair_id = ? AND o.thread_id IS ?
              AND NOT EXISTS (SELECT 1 FROM sms_message m WHERE m.pair_id = o.pair_id AND m.local_id = o.local_id)
            ORDER BY o.created_at
            """, arguments: [pairId, threadId])
    }

    public static func thread(_ db: Database, pairId: String, threadId: Int64) throws -> SmsThread? {
        try SmsThread.fetchOne(db, sql: "SELECT * FROM sms_thread WHERE pair_id = ? AND thread_id = ?",
                               arguments: [pairId, threadId])
    }

    /// A conversation with exactly this one address, for "New Message" to a number that already has one.
    public static func thread(_ db: Database, pairId: String, address: String) throws -> SmsThread? {
        try SmsThread.fetchOne(db, sql: "SELECT * FROM sms_thread WHERE pair_id = ? AND addresses_json = ? "
                                   + "ORDER BY last_ts DESC LIMIT 1", arguments: [pairId, AddressList.json([address])])
    }

    public func threads(pairId: String, after last: SmsThread? = nil, limit: Int = pageSize) async throws -> [SmsThread] {
        try await pool.read { db in try Self.threads(db, pairId: pairId, after: last, limit: limit) }
    }

    public func messages(pairId: String, threadId: Int64, before last: SmsMessage? = nil,
                         limit: Int = pageSize) async throws -> [SmsMessage] {
        try await pool.read { db in
            try Self.messages(db, pairId: pairId, threadId: threadId, before: last, limit: limit)
        }
    }

    public func placeholders(pairId: String, threadId: Int64?) async throws -> [SmsOutboxEntry] {
        try await pool.read { db in try Self.placeholders(db, pairId: pairId, threadId: threadId) }
    }

    public func thread(pairId: String, threadId: Int64) async throws -> SmsThread? {
        try await pool.read { db in try Self.thread(db, pairId: pairId, threadId: threadId) }
    }
}
