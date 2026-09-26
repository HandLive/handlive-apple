import Foundation
import GRDB
import HLProtocol

/// The SMS queries of 05-sms.md on the encrypted database: every write of a page, an event or an outbox change runs in
/// one transaction on GRDB's writer (never on the main thread).
public struct SmsStore: Sendable {
    public let database: SmsDatabase

    public init(database: SmsDatabase) {
        self.database = database
    }

    var pool: DatabasePool { database.pool }

    // MARK: - SMS-01

    /// Step 3: the pair's current cursor.
    public func cursor(pairId: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT cursor FROM sync_cursor WHERE pair_id = ? AND stream = 'sms'",
                                arguments: [pairId])
        }
    }

    /// When the cursor was saved (Settings › Messages, SMS-01 field 4).
    public func lastSync(pairId: String) async throws -> Int64? {
        try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT updated_at FROM sync_cursor WHERE pair_id = ? AND stream = 'sms'",
                               arguments: [pairId])
        }
    }

    /// Step 7, and step 9 on the last page: the page, its unread reconciliation and the new cursor in one transaction.
    public func applySyncPage(_ page: SmsSyncAckData, pairId: String, now: Int64) async throws {
        try await pool.write { db in
            for thread in page.threads { try Self.upsertThread(db, thread, pairId: pairId) }
            for message in page.messages { try Self.upsertMessage(db, message, pairId: pairId) }
            guard !page.hasMore else { return }
            try Self.applyUnread(db, page.unread ?? [], pairId: pairId)
            try db.execute(sql: """
                INSERT INTO sync_cursor (pair_id, stream, cursor, updated_at) VALUES (?, 'sms', ?, ?)
                ON CONFLICT (pair_id, stream) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at
                """, arguments: [pairId, page.cursor, now])
        }
    }

    /// A2 (and E5 for a stale cursor): forget the cursor and the synced messages, keep what still waits to be sent.
    public func resetForResync(pairId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM sync_cursor WHERE pair_id = ? AND stream = 'sms'", arguments: [pairId])
            try db.execute(sql: """
                DELETE FROM sms_outbox
                WHERE pair_id = ?
                  AND (state IN ('sent', 'delivered')
                       OR local_id IN (SELECT local_id FROM sms_message WHERE pair_id = ? AND local_id IS NOT NULL))
                """, arguments: [pairId, pairId])
            try db.execute(sql: "DELETE FROM sms_message WHERE pair_id = ?", arguments: [pairId])
            try db.execute(sql: "DELETE FROM sms_thread WHERE pair_id = ?", arguments: [pairId])
        }
    }

    // MARK: - SMS-02, SMS-04 API 4

    /// Step 6: the message and its conversation in one transaction; a sent message without `local_id` is matched to a
    /// placeholder of this device (API 4 logic 3). Returns whether the row is new (only new inbox rows notify).
    @discardableResult
    public func applyNew(_ new: SmsNewData, pairId: String) async throws -> Bool {
        try await pool.write { db in
            let existed = try Bool.fetchOne(db, sql: "SELECT 1 FROM sms_message WHERE pair_id = ? AND message_key = ?",
                                            arguments: [pairId, new.message.messageKey]) ?? false
            try Self.upsertThread(db, new.thread, pairId: pairId)
            try Self.upsertMessage(db, new.message, pairId: pairId)
            return !existed
        }
    }

    // MARK: - SMS-03

    /// Step 11: older messages never overwrite what is stored.
    public func insertHistory(_ messages: [SmsMessageData], pairId: String) async throws {
        try await pool.write { db in
            for message in messages where message.box != .unrecognized {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO sms_message (pair_id, message_key, thread_id, address, body, box, ts, ts_sent,
                                                       read, sub_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [pairId, message.messageKey, message.threadId, message.address, message.body,
                                     Self.box(message.box), message.ts, message.tsSent, message.read, message.subId])
            }
        }
    }

    /// Step 9: `before_ts` = the oldest stored message of the conversation, or now when there is none.
    public func oldestTimestamp(pairId: String, threadId: Int64) async throws -> Int64? {
        try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM sms_message WHERE pair_id = ? AND thread_id = ?",
                               arguments: [pairId, threadId])
        }
    }

    // MARK: - SMS-05

    /// Step 6: the phone's unread count and the read flags up to `read_up_to_ts`; unknown conversations are ignored (E4).
    public func applyReadState(_ state: SmsReadState, pairId: String) async throws {
        try await pool.write { db in try Self.applyReadState(db, state, pairId: pairId) }
    }

    /// A2 (SMS-03 step 4, quick reply): read on this device only; the phone is not told (E3).
    public func markLocallyRead(pairId: String, threadId: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE sms_thread SET local_read_ts = last_ts WHERE pair_id = ? AND thread_id = ?",
                           arguments: [pairId, threadId])
        }
    }

    /// Badge: conversations shown as unread (SMS-02 field 6, SMS-05 field 4).
    public func unreadThreadCount(pairId: String) async throws -> Int {
        try await pool.read { db in try Self.unreadThreadCount(db, pairId: pairId) }
    }

    static func unreadThreadCount(_ db: Database, pairId: String) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sms_thread WHERE pair_id = ? AND unread_count > 0 AND local_read_ts < last_ts
            """, arguments: [pairId]) ?? 0
    }

    // MARK: - Pairs (PAIR-03 step 7, SET-02 A4)

    /// Deletes every synced row and the queue of one pair.
    public func deletePair(_ pairId: String) async throws {
        try await pool.write { db in
            for table in ["sms_message", "sms_thread", "sms_outbox", "sync_cursor"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE pair_id = ?", arguments: [pairId])
            }
        }
    }

    public func deleteAll() async throws {
        try await pool.write { db in
            for table in ["sms_message", "sms_thread", "sms_outbox", "sync_cursor"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
