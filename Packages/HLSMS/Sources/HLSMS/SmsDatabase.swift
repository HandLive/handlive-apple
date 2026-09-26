import Foundation
import GRDB

/// Why the SMS database could not be used (SMS-01 E7, SMS-03 E6).
public enum SmsDatabaseError: Error, Equatable, Sendable {
    /// The linked SQLite is not SQLCipher: never fall back to a plaintext file (0.6.5).
    case encryptionUnavailable
    /// `db_key` is not 32 bytes.
    case invalidKey
}

/// `handlive.sqlite` (0.9.3): the SMS tables in a SQLCipher database keyed with the raw 32-byte `db_key` from the
/// Keychain (0.6.1, SET-03 Query `PRAGMA key = "x'<hex>'"`). The pairs stay in the sealed pair store, so the tables
/// carry `pair_id` without a foreign key; PAIR-03 and SET-02 delete a pair's rows explicitly.
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
            guard try String.fetchOne(db, sql: "PRAGMA cipher_version") != nil else {
                throw SmsDatabaseError.encryptionUnavailable
            }
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        self.url = url
        try Self.migrator.migrate(pool)
    }

    /// `<Application Support>/<bundle id>/handlive.sqlite`: the Mac's data folder, and on iOS the app's own container
    /// (the Notification Service Extension never opens the database, so it stays out of the shared App Group).
    public static func defaultURL(bundleIdentifier: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(bundleIdentifier, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Closes the pool and deletes the file with its `-wal` and `-shm` companions (SET-02 API 7).
    public func deleteFiles() throws {
        try pool.close()
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-sms") { db in
            try db.execute(sql: Self.smsSchema)
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
}
