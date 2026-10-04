import Foundation
import GRDB

/// Why the SMS database could not be used (SMS-01 E7, SMS-03 E6).
public enum SmsDatabaseError: Error, Equatable, Sendable {
    /// The linked SQLite is not SQLCipher: never fall back to a plaintext file (0.6.5).
    case encryptionUnavailable
    /// `db_key` is not 32 bytes.
    case invalidKey
}

/// `handlive.sqlite` (0.9.3): the SMS tables and the call log in a SQLCipher database keyed with the raw 32-byte
/// `db_key` from the Keychain (0.6.1, SET-03 Query `PRAGMA key = "x'<hex>'"`). The pairs stay in the sealed pair store,
/// so the tables carry `pair_id` without a foreign key; PAIR-03 and SET-02 delete a pair's rows explicitly. The call
/// log's queries live with the calls (`HLCalls`); this type only owns the file and its migrations.
public final class SmsDatabase: Sendable {
    public static let fileName = "handlive.sqlite"

    public let pool: DatabasePool
    public let url: URL

    /// Opens (creating when needed) the database at `url` and runs the migrations. The directory is created with the
    /// "until first unlock" protection class: the apps write while the screen is locked (0.9.3).
    public init(url: URL, key: Data) throws {
        guard key.count == 32 else { throw SmsDatabaseError.invalidKey }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: directory.path)
        #endif
        var configuration = Configuration()
        let hexKey = key.map { String(format: "%02x", $0) }.joined()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA key = \"x'\(hexKey)'\"")
            // Pin the SQLCipher 4 format: a library update with other defaults must not read the file as
            // SQLITE_NOTADB, which would leave the user's database for the second slot (SET-03 API 1 logic 5).
            try db.execute(sql: "PRAGMA cipher_compatibility = 4")
            guard try String.fetchOne(db, sql: "PRAGMA cipher_version") != nil else {
                throw SmsDatabaseError.encryptionUnavailable
            }
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        self.url = url
        try Self.migrator.migrate(pool)
    }

    /// SET-03 API 1 logic 5: opens the database this `db_key` can use. When SQLCipher finds no database under the key
    /// at `url` (`SQLITE_NOTADB`: sealed with a `db_key` this install does not have, or its first page is damaged), or
    /// `url` holds no database, the second slot `<url>.alt` is used when it opens with the key or holds none (a new
    /// empty database, which syncs again from the phone); the other key's database stays where it is, so switching back
    /// to the build that wrote it finds its data again. When both slots hold another key's database, the one modified
    /// longest ago gives way (one generation is kept). Every other error is thrown and changes no slot.
    public static func open(url: URL, key: Data) throws -> SmsDatabase {
        let alt = altURL(for: url)
        // Before any attempt: opening with a wrong key can checkpoint a leftover -wal and touch the files, which would
        // make the slot tried last look like the one used last.
        let urlModified = modified(url), altModified = modified(alt)
        guard exists(url) else {
            if exists(alt), let database = try? SmsDatabase(url: alt, key: key) { return database }
            try removeSet(at: url) // a -wal or -shm without its database holds nothing worth keeping
            return try SmsDatabase(url: url, key: key)
        }
        do {
            return try SmsDatabase(url: url, key: key)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            guard exists(alt) else {
                try removeSet(at: alt)
                return try SmsDatabase(url: alt, key: key)
            }
            do {
                return try SmsDatabase(url: alt, key: key)
            } catch let altError as DatabaseError where altError.resultCode == .SQLITE_NOTADB {
                let older = urlModified < altModified ? url : alt
                try removeSet(at: older)
                return try SmsDatabase(url: older, key: key)
            }
        }
    }

    /// The second slot of SET-03 API 1 logic 5: `handlive.sqlite.alt`, with its `-wal` and `-shm` beside it.
    public static func altURL(for url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".alt")
    }

    private static let suffixes = ["-wal", "-shm", ""] // the database file last: never a -wal left without it

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The latest modification of a database's files: with WAL, the database file itself changes only at checkpoints.
    private static func modified(_ url: URL) -> Date {
        suffixes.compactMap { suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            return attributes?[.modificationDate] as? Date
        }.max() ?? .distantPast
    }

    private static func removeSet(at url: URL) throws {
        for suffix in suffixes where exists(URL(fileURLWithPath: url.path + suffix)) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// `<Application Support>/<bundle id>/handlive.sqlite`: the Mac's data folder, and on iOS the app's own container
    /// (the Notification Service Extension never opens the database, so it stays out of the shared App Group).
    public static func defaultURL(bundleIdentifier: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(bundleIdentifier, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Closes the pool and deletes the file with its `-wal` and `-shm` companions (SET-02 API 7; `removeFiles` deletes
    /// both slots). The files go even when a connection cannot close: `db_key` is deleted first, so what is left cannot
    /// be read anyway.
    public func deleteFiles() throws {
        try? pool.close()
        try Self.removeSet(at: url)
    }

    /// Deletes a database's files without opening it (no key, or it could not be opened), both slots of SET-03 API 1
    /// logic 5; missing files are fine.
    public static func removeFiles(at url: URL) throws {
        try removeSet(at: url)
        try removeSet(at: altURL(for: url))
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-sms") { db in
            try db.execute(sql: Self.smsSchema)
        }
        migrator.registerMigration("v2-call-log") { db in
            try db.execute(sql: Self.callLogSchema)
        }
        return migrator
    }

    /// The SMS part of 0.9.3 (`sms_thread`, `sms_message`, `sms_outbox`, `sync_cursor`).
    static let smsSchema = """
        CREATE TABLE sms_thread (
          pair_id           TEXT    NOT NULL,
          thread_id         INTEGER NOT NULL,
          addresses_json    TEXT    NOT NULL,
          display_name      TEXT,
          snippet           TEXT,
          last_ts           INTEGER NOT NULL,
          unread_count      INTEGER NOT NULL DEFAULT 0,
          local_read_ts     INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (pair_id, thread_id)
        );
        CREATE TABLE sms_message (
          pair_id           TEXT    NOT NULL,
          message_key       TEXT    NOT NULL,
          thread_id         INTEGER NOT NULL,
          address           TEXT    NOT NULL,
          body              TEXT    NOT NULL,
          box               TEXT    NOT NULL CHECK (box IN ('inbox','sent','outbox','failed','queued')),
          ts                INTEGER NOT NULL,
          ts_sent           INTEGER,
          read              INTEGER NOT NULL DEFAULT 0,
          sub_id            INTEGER,
          local_id          TEXT,
          PRIMARY KEY (pair_id, message_key)
        );
        CREATE INDEX idx_sms_message_thread_ts ON sms_message (pair_id, thread_id, ts DESC);
        CREATE TABLE sms_outbox (
          local_id          TEXT    PRIMARY KEY,
          pair_id           TEXT    NOT NULL,
          thread_id         INTEGER,
          addresses_json    TEXT    NOT NULL,
          body              TEXT    NOT NULL,
          sub_id            INTEGER,
          state             TEXT    NOT NULL CHECK (state IN ('pending','sending','sent','delivered','failed')),
          attempts          INTEGER NOT NULL DEFAULT 0,
          last_error        TEXT,
          created_at        INTEGER NOT NULL,
          updated_at        INTEGER NOT NULL
        );
        CREATE TABLE sync_cursor (
          pair_id           TEXT    NOT NULL,
          stream            TEXT    NOT NULL CHECK (stream IN ('sms','calllog')),
          cursor            TEXT    NOT NULL,
          updated_at        INTEGER NOT NULL,
          PRIMARY KEY (pair_id, stream)
        );
        """

    /// The call log of 0.9.3 (`call_log_entry`, CALL-04); its cursor is the `calllog` row of `sync_cursor`.
    static let callLogSchema = """
        CREATE TABLE call_log_entry (
          pair_id           TEXT    NOT NULL,
          entry_id          INTEGER NOT NULL,
          number            TEXT,
          display_name      TEXT,
          type              TEXT    NOT NULL CHECK (type IN ('incoming','outgoing','missed','rejected','blocked','voicemail')),
          ts                INTEGER NOT NULL,
          duration_s        INTEGER NOT NULL DEFAULT 0,
          sub_id            INTEGER,
          seen              INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (pair_id, entry_id)
        );
        CREATE INDEX idx_call_log_ts ON call_log_entry (pair_id, ts DESC);
        """
}
