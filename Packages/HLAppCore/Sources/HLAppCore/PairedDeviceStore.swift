import Foundation
import HLCrypto

/// Pair records of this device, kept in one file encrypted with `db_key` (XChaCha20-Poly1305). Phase 1 keeps only
/// `paired_device`; the SQLCipher database of 0.9.3 comes with the SMS tables in Phase 2 behind the same API.
public final class PairedDeviceStore: @unchecked Sendable {
    static let aad = Data("handlive/v1/paired-devices".utf8)
    private let fileURL: URL
    private let key: Data
    private let lock = NSLock()

    public init(fileURL: URL, databaseKey: Data) {
        self.fileURL = fileURL
        key = databaseKey
    }

    /// `~/Library/Application Support/<bundle id>/paired-devices.bin`.
    public static func defaultURL(bundleIdentifier: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("paired-devices.bin")
    }

    /// Every record, tombstones included. A missing file is an empty store; an unreadable one throws.
    public func all() throws -> [PairedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try read()
    }

    /// The active pair (not revoked), if any: a Mac/iPhone pairs with one phone at a time (README §4).
    public func active() throws -> PairedDeviceRecord? {
        try all().first { $0.revokedAt == nil }
    }

    /// Inserts or replaces the record with the same `pair_id`.
    public func upsert(_ record: PairedDeviceRecord) throws {
        try mutate { records in
            records.removeAll { $0.pairId == record.pairId }
            records.append(record)
        }
    }

    public func update(pairId: String, _ change: (inout PairedDeviceRecord) -> Void) throws {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.pairId == pairId }) else { return }
            change(&records[index])
        }
    }

    public func remove(pairId: String) throws {
        try mutate { $0.removeAll { $0.pairId == pairId } }
    }

    /// SET-03 API 1 logic 5: the store this `db_key` can use. A file whose tag does not verify under the key was sealed
    /// with a key this install does not have (the keys were recreated after the Keychain lost them, or a build signed by
    /// another team reads another keychain access group); using it would make every new pair fail to save. So the
    /// second slot `<file>.alt` is used instead, and the other key's file stays where it is: switching back to the
    /// build that wrote it finds its pairs again. When both slots hold another key's file, the one modified longest ago
    /// gives way (one generation is kept). Any other error keeps `fileURL` and changes no slot.
    public static func open(fileURL: URL, databaseKey: Data) -> PairedDeviceStore {
        let main = PairedDeviceStore(fileURL: fileURL, databaseKey: databaseKey)
        let alt = PairedDeviceStore(fileURL: altURL(for: fileURL), databaseKey: databaseKey)
        switch (main.slotState(), alt.slotState()) {
        case (.opens, _), (.unreadable, _), (.otherKey, .unreadable): return main
        case (.absent, .opens), (.otherKey, .opens), (.otherKey, .absent): return alt
        case (.absent, _): return main
        case (.otherKey, .otherKey):
            let older = main.modified < alt.modified ? main : alt
            try? FileManager.default.removeItem(at: older.fileURL)
            return older
        }
    }

    /// The second slot of SET-03 API 1 logic 5: `paired-devices.bin.alt`.
    public static func altURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".alt")
    }

    /// SET-02 API 7: deletes both slots; missing files count as deleted.
    public static func deleteFiles(at fileURL: URL) throws {
        for file in [fileURL, altURL(for: fileURL)] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private enum SlotState {
        case opens, absent, otherKey, unreadable
    }

    private func slotState() -> SlotState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        do {
            _ = try all()
            return .opens
        } catch CryptoError.authenticationFailed {
            return .otherKey
        } catch {
            return .unreadable
        }
    }

    private var modified: Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    private func mutate(_ change: (inout [PairedDeviceRecord]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var records = try read()
        change(&records)
        try write(records)
    }

    private func read() throws -> [PairedDeviceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let sealed = try Data(contentsOf: fileURL)
        let plaintext = try XChaCha20Poly1305.open(combined: sealed, key: key, aad: Self.aad)
        return try JSONDecoder().decode([PairedDeviceRecord].self, from: plaintext)
    }

    private func write(_ records: [PairedDeviceRecord]) throws {
        let plaintext = try JSONEncoder().encode(records)
        let sealed = try XChaCha20Poly1305.seal(plaintext, key: key, aad: Self.aad).combined
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Class C, not "complete": the menu bar app keeps connecting and updating the pair while the screen is locked,
        // and complete protection refuses every write then. The content is sealed with db_key anyway.
        try sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
