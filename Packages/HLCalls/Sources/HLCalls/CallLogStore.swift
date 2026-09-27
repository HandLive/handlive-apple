import Foundation
import GRDB
import HLProtocol
import HLSMS

/// One row of `call_log_entry` (0.9.3).
public struct CallLogRecord: Equatable, Sendable, Identifiable {
    public let entryId: Int64
    public let number: String?
    public let displayName: String?
    public let type: CallLogType
    /// When the call started.
    public let ts: Int64
    public let durationS: Int32
    public let subId: Int32?
    /// A missed call already seen on this device (CALL-04 field 7).
    public let seen: Bool

    public var id: Int64 { entryId }

    /// A missed call not seen yet: bold, and counted in the badge.
    public var isUnseenMissed: Bool { type == .missed && !seen }

    init(row: Row) {
        entryId = row["entry_id"]
        number = row["number"]
        displayName = row["display_name"]
        type = CallLogType(rawValue: row["type"] ?? "") ?? .unrecognized
        ts = row["ts"]
        durationS = row["duration_s"]
        subId = row["sub_id"]
        seen = row["seen"]
    }
}

/// The call log in the encrypted database (CALL-04 Query): pages written with their cursor in one transaction, `log_new`
/// upserts that keep `seen`, the list, the badge and seen marks, and the per-pair deletes.
public final class CallLogStore: Sendable {
    /// Rows per page of the list (CALL-04 field 1 Query, `LIMIT 100`).
    public static let pageSize = 100
    /// The client keeps entries for 90 days (`CALLLOG_SYNC_WINDOW`, CALL-04 special requirements).
    public static let retentionMs: Int64 = 7_776_000_000

    public let database: SmsDatabase
    var pool: DatabasePool { database.pool }

    public init(database: SmsDatabase) {
        self.database = database
    }

    /// Step 3: the stored cursor of the pair's call log.
    public func cursor(pairId: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT cursor FROM sync_cursor WHERE pair_id = ? AND stream = 'calllog'",
                                arguments: [pairId])
        }
    }

    /// When the cursor was last stored (Settings › Calls, field 11).
    public func lastSync(pairId: String) async throws -> Int64? {
        try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT updated_at FROM sync_cursor WHERE pair_id = ? AND stream = 'calllog'",
                               arguments: [pairId])
        }
    }

    /// Step 5: one page and its cursor in one transaction. `reset` first deletes the pair's call log (E5). New entries are
    /// seen already on a first sync, on a reset and when they are not missed calls; later missed ones are not. Entries
    /// of a type this app does not know are left out (the table only takes the six types).
    @discardableResult
    public func writePage(_ page: CallLogSyncAckData, pairId: String, firstSync: Bool, now: Int64) async throws -> Int {
        try await pool.write { db in
            if page.reset { try db.execute(sql: "DELETE FROM call_log_entry WHERE pair_id = ?", arguments: [pairId]) }
            var written = 0
            for entry in page.entries where entry.type != .unrecognized {
                let seen = firstSync || page.reset || entry.type != .missed
                _ = try Self.upsert(db, entry, pairId: pairId, seenIfNew: seen)
                written += 1
            }
            try db.execute(sql: """
                INSERT INTO sync_cursor (pair_id, stream, cursor, updated_at) VALUES (?, 'calllog', ?, ?)
                ON CONFLICT (pair_id, stream) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at
                """, arguments: [pairId, page.cursor, now])
            return written
        }
    }

    /// Step 9: a `log_new` entry, keeping any existing `seen`; `true` when the entry was not there before, so a missed
    /// call is notified at most once (special requirements).
    public func applyNew(_ entry: CallLogEntryData, pairId: String) async throws -> Bool {
        guard entry.type != .unrecognized else { return false }
        return try await pool.write { db in
            try Self.upsert(db, entry, pairId: pairId, seenIfNew: entry.type != .missed)
        }
    }

    /// The upsert of CALL-04 Query (steps 5 and 9); returns whether the row is new.
    static func upsert(_ db: Database, _ entry: CallLogEntryData, pairId: String, seenIfNew: Bool) throws -> Bool {
        let existed = try Bool.fetchOne(db, sql: "SELECT 1 FROM call_log_entry WHERE pair_id = ? AND entry_id = ?",
                                        arguments: [pairId, entry.entryId]) ?? false
        try db.execute(sql: """
            INSERT INTO call_log_entry (pair_id, entry_id, number, display_name, type, ts, duration_s, sub_id, seen)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (pair_id, entry_id) DO UPDATE SET
              number = excluded.number, display_name = excluded.display_name, type = excluded.type,
              ts = excluded.ts, duration_s = excluded.duration_s, sub_id = excluded.sub_id
            """, arguments: [pairId, entry.entryId, entry.number, entry.displayName, entry.type.rawValue, entry.ts,
                             entry.durationS, entry.subId, seenIfNew])
        return !existed
    }

    /// Field 1: the newest `limit` entries (the list grows by pages of 100 as it scrolls).
    static func entries(_ db: Database, pairId: String, limit: Int) throws -> [CallLogRecord] {
        try Row.fetchAll(db, sql: """
            SELECT entry_id, number, display_name, type, ts, duration_s, sub_id, seen
            FROM call_log_entry WHERE pair_id = ? ORDER BY ts DESC, entry_id DESC LIMIT ?
            """, arguments: [pairId, limit]).map(CallLogRecord.init(row:))
    }

    public func entries(pairId: String, limit: Int = pageSize) async throws -> [CallLogRecord] {
        try await pool.read { db in try Self.entries(db, pairId: pairId, limit: limit) }
    }

    /// Field 7: the pair's missed calls not seen on this device.
    static func unseenMissed(_ db: Database, pairId: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_log_entry WHERE pair_id = ? AND type = 'missed' AND seen = 0",
                         arguments: [pairId]) ?? 0
    }

    public func unseenMissedCount(pairId: String) async throws -> Int {
        try await pool.read { db in try Self.unseenMissed(db, pairId: pairId) }
    }

    /// Step 12: the call list opened, every missed call of the pair is seen.
    public func markAllMissedSeen(pairId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE call_log_entry SET seen = 1 WHERE pair_id = ? AND type = 'missed' AND seen = 0",
                           arguments: [pairId])
        }
    }

    /// Step 12: one missed-call notification tapped.
    public func markSeen(pairId: String, entryId: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE call_log_entry SET seen = 1 WHERE pair_id = ? AND entry_id = ?",
                           arguments: [pairId, entryId])
        }
    }

    /// Daily: keep only 90 days.
    public func deleteOlderThan(_ ts: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM call_log_entry WHERE ts < ?", arguments: [ts])
        }
    }

    /// PAIR-03 step 7: the pair's call log and its cursor go with the pair.
    public func deletePair(_ pairId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM call_log_entry WHERE pair_id = ?", arguments: [pairId])
            try db.execute(sql: "DELETE FROM sync_cursor WHERE pair_id = ? AND stream = 'calllog'", arguments: [pairId])
        }
    }
}
