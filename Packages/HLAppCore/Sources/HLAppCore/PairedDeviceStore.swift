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
