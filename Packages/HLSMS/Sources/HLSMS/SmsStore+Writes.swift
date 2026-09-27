import Foundation
import GRDB
import HLProtocol

extension SmsStore {
    /// SMS-01 step 7: upsert a conversation, keeping `local_read_ts`.
    static func upsertThread(_ db: Database, _ thread: SmsThreadData, pairId: String) throws {
        try db.execute(sql: """
            INSERT INTO sms_thread (pair_id, thread_id, addresses_json, display_name, snippet, last_ts, unread_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (pair_id, thread_id) DO UPDATE SET
              addresses_json = excluded.addresses_json, display_name = excluded.display_name,
              snippet = excluded.snippet, last_ts = excluded.last_ts, unread_count = excluded.unread_count
            """, arguments: [pairId, thread.threadId, AddressList.json(thread.addresses), thread.displayName,
                             thread.snippet, thread.lastTs, thread.unreadCount])
    }

    /// SMS-02 step 6: upsert a message, keeping a `local_id` already attached; then SMS-04 API 4 logic 3–4: a sent
    /// message without `local_id` takes the one of the matching placeholder, and the placeholder's status moves on.
    static func upsertMessage(_ db: Database, _ message: SmsMessageData, pairId: String) throws {
        guard message.box != .unrecognized else { return } // a box of a newer phone: skipped (0.5.1 rule 6)
        try db.execute(sql: """
            INSERT INTO sms_message (pair_id, message_key, thread_id, address, body, box, ts, ts_sent, read, sub_id,
                                     local_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (pair_id, message_key) DO UPDATE SET
              thread_id = excluded.thread_id, address = excluded.address, body = excluded.body,
              box = excluded.box, ts = excluded.ts, ts_sent = excluded.ts_sent,
              read = excluded.read, sub_id = excluded.sub_id,
              local_id = COALESCE(excluded.local_id, sms_message.local_id)
            """, arguments: [pairId, message.messageKey, message.threadId, message.address, message.body,
                             box(message.box), message.ts, message.tsSent, message.read, message.subId, message.localId])
        guard message.box == .sent || message.box == .failed else { return }
        var localId = try String.fetchOne(db, sql: "SELECT local_id FROM sms_message WHERE pair_id = ? AND message_key = ?",
                                          arguments: [pairId, message.messageKey])
        if localId == nil, let matched = try fallbackMatch(db, message, pairId: pairId) {
            try db.execute(sql: "UPDATE sms_message SET local_id = ? WHERE pair_id = ? AND message_key = ?",
                           arguments: [matched, pairId, message.messageKey])
            localId = matched
        }
        guard let localId else { return }
        // The phone's copy settles the placeholder even when its sms/status was missed (forward-only rule).
        let state: SmsSendState = message.box == .sent ? .sent : .failed
        try transition(db, localId: localId, to: state,
                       error: state == .failed ? ErrorCode.smsGenericFailure.rawValue : nil,
                       now: HLUUID.currentTimeMs())
    }

    /// SMS-04 API 4 logic 3: the oldest unmatched placeholder with the same recipient and text, created within the ten
    /// minutes before `ts`.
    private static func fallbackMatch(_ db: Database, _ message: SmsMessageData, pairId: String) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT o.local_id FROM sms_outbox o
            WHERE o.pair_id = ? AND o.addresses_json = ? AND o.body = ? AND o.created_at >= ? - 600000
              AND NOT EXISTS (SELECT 1 FROM sms_message m WHERE m.pair_id = o.pair_id AND m.local_id = o.local_id)
            ORDER BY o.created_at LIMIT 1
            """, arguments: [pairId, AddressList.json([message.address]), message.body, message.ts])
    }

    /// SMS-01 step 9: conversations missing from `unread` are fully read; the others as in SMS-05 step 6.
    static func applyUnread(_ db: Database, _ unread: [SmsReadState], pairId: String) throws {
        let ids = unread.map(\.threadId)
        let list = ids.isEmpty ? "()" : "(" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")"
        var arguments: StatementArguments = [pairId]
        arguments += StatementArguments(ids)
        try db.execute(sql: "UPDATE sms_thread SET unread_count = 0 WHERE pair_id = ? AND unread_count <> 0 "
                           + "AND thread_id NOT IN \(list)", arguments: arguments)
        try db.execute(sql: "UPDATE sms_message SET read = 1 WHERE pair_id = ? AND box = 'inbox' AND read = 0 "
                           + "AND thread_id NOT IN \(list)", arguments: arguments)
        for state in unread { try applyReadState(db, state, pairId: pairId) }
    }

    /// SMS-05 step 6.
    static func applyReadState(_ db: Database, _ state: SmsReadState, pairId: String) throws {
        try db.execute(sql: "UPDATE sms_thread SET unread_count = ? WHERE pair_id = ? AND thread_id = ?",
                       arguments: [state.unreadCount, pairId, state.threadId])
        try db.execute(sql: """
            UPDATE sms_message SET read = CASE WHEN ts <= ? THEN 1 ELSE 0 END
            WHERE pair_id = ? AND thread_id = ? AND box = 'inbox' AND read <> CASE WHEN ts <= ? THEN 1 ELSE 0 END
            """, arguments: [state.readUpToTs, pairId, state.threadId, state.readUpToTs])
    }

    /// SMS-04 steps 6, 7, 9: status transition, forward only.
    static func transition(_ db: Database, localId: String, to state: SmsSendState, error: String?, now: Int64) throws {
        try db.execute(sql: """
            UPDATE sms_outbox SET state = ?, last_error = ?, updated_at = ?
            WHERE local_id = ?
              AND ((? = 'sending'   AND state = 'pending')
                OR (? = 'sent'      AND state IN ('pending', 'sending'))
                OR (? = 'delivered' AND state IN ('pending', 'sending', 'sent'))
                OR (? = 'failed'    AND state IN ('pending', 'sending')))
            """, arguments: [state.rawValue, error, now, localId, state.rawValue, state.rawValue, state.rawValue,
                             state.rawValue])
    }

    /// The `box` column value; callers skip `.unrecognized` before writing.
    static func box(_ box: SmsBox) -> String {
        box.rawValue
    }
}
