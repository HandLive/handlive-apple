import Foundation
import GRDB
import HLProtocol

/// A message written on this device, as queued in `sms_outbox` (SMS-04 step 3).
public struct SmsDraft: Equatable, Sendable {
    public let localId: String
    public let threadId: Int64?
    public let addresses: [String]
    public let body: String
    public let subId: Int32?

    public init(localId: String = HLUUID.v7(), threadId: Int64?, addresses: [String], body: String, subId: Int32?) {
        self.localId = localId
        self.threadId = threadId
        self.addresses = addresses
        self.body = body
        self.subId = subId
    }
}

extension SmsStore {
    /// `SMS_OUTBOX_EXPIRY`: waiting longer → `failed` with `NOT_CONNECTED` (E1).
    public static let outboxExpiryMs: Int64 = 24 * 3600 * 1000
    /// Completed entries are dropped after 30 days; the real message stays in `sms_message`.
    public static let outboxRetentionMs: Int64 = 30 * 24 * 3600 * 1000

    /// SMS-04 step 3: a new placeholder in `pending`.
    public func enqueue(_ draft: SmsDraft, pairId: String, now: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO sms_outbox (local_id, pair_id, thread_id, addresses_json, body, sub_id, state, attempts,
                                        created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """, arguments: [draft.localId, pairId, draft.threadId, AddressList.json(draft.addresses), draft.body,
                                 draft.subId, now, now])
        }
    }

    /// Step 5: one more try of `sms/send`.
    public func recordAttempt(localId: String, now: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE sms_outbox SET attempts = attempts + 1, updated_at = ? WHERE local_id = ?",
                           arguments: [now, localId])
        }
    }

    /// Steps 6, 7, 9 (API 2 logic 2): forward-only; returns whether the state changed.
    @discardableResult
    public func transition(localId: String, to state: SmsSendState, error: String? = nil, now: Int64) async throws -> Bool {
        try await pool.write { db in
            try Self.transition(db, localId: localId, to: state, error: error, now: now)
            return db.changesCount > 0
        }
    }

    /// Step 5 on a new session: the entries still waiting, oldest first (CONN-02 step 10).
    public func pending(pairId: String) async throws -> [SmsOutboxEntry] {
        try await pool.read { db in
            try SmsOutboxEntry.fetchAll(db, sql: "SELECT * FROM sms_outbox WHERE pair_id = ? AND state = 'pending' "
                                            + "ORDER BY created_at", arguments: [pairId])
        }
    }

    /// "2 messages waiting for the phone" (CONN-02 field 5).
    public func pendingCount(pairId: String) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sms_outbox WHERE pair_id = ? AND state = 'pending'",
                             arguments: [pairId]) ?? 0
        }
    }

    public func outboxEntry(localId: String) async throws -> SmsOutboxEntry? {
        try await pool.read { db in
            try SmsOutboxEntry.fetchOne(db, sql: "SELECT * FROM sms_outbox WHERE local_id = ?", arguments: [localId])
        }
    }

    /// At launch and every hour: entries waiting more than 24 h fail with `NOT_CONNECTED` (E1); completed entries older
    /// than 30 days are dropped.
    public func expireOutbox(now: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE sms_outbox SET state = 'failed', last_error = 'NOT_CONNECTED', updated_at = ?
                WHERE state = 'pending' AND created_at < ? - ?
                """, arguments: [now, now, Self.outboxExpiryMs])
            try db.execute(sql: "DELETE FROM sms_outbox WHERE state IN ('sent', 'delivered') AND updated_at < ? - ?",
                           arguments: [now, Self.outboxRetentionMs])
        }
    }

    /// A1: "Try Again" drops the failed entry; the caller queues the same text under a new `local_id`.
    public func removeFailed(localId: String) async throws -> SmsOutboxEntry? {
        try await pool.write { db in
            let entry = try SmsOutboxEntry.fetchOne(db, sql: "SELECT * FROM sms_outbox WHERE local_id = ? AND state = 'failed'",
                                                    arguments: [localId])
            try db.execute(sql: "DELETE FROM sms_outbox WHERE local_id = ? AND state = 'failed'", arguments: [localId])
            return entry
        }
    }
}
