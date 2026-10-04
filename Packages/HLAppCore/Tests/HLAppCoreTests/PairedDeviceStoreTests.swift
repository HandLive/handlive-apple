import Foundation
import HLCrypto
import Testing
@testable import HLAppCore

@Suite("Paired device store")
struct PairedDeviceStoreTests {
    private func record(_ id: String) -> PairedDeviceRecord {
        PairedDeviceRecord(pairId: id, peerDeviceId: "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f", peerName: "Pixel 8",
                           peerModel: "Pixel 8", peerSigningPublicKey: Data(count: 32),
                           peerKeyAgreementPublicKey: Data(count: 32),
                           peerCertificateSHA256: Data(repeating: 1, count: 32), attestation: Data("HLPAIR1".utf8),
                           signatureSelf: Data(count: 64), signaturePeer: Data(count: 64), createdAt: 1)
    }

    @Test("Encrypted round trip; a wrong key cannot read it; tombstones are not active")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl-\(UUID().uuidString)/pairs.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = Data(repeating: 7, count: 32)
        let store = PairedDeviceStore(fileURL: url, databaseKey: key)
        #expect(try store.all().isEmpty)
        try store.upsert(record("3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"))
        try store.update(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d") { $0.lastHost = "192.168.1.23" }
        #expect(try store.active()?.lastHost == "192.168.1.23")
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("Pixel 8".utf8)) == nil) // encrypted at rest
        #expect(throws: (any Error).self) { _ = try PairedDeviceStore(fileURL: url, databaseKey: Data(count: 32)).all() }
        try store.update(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d") { $0.revokedAt = 9 }
        #expect(try store.active() == nil)
        #expect(try store.all().count == 1)
        try store.remove(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")
        #expect(try store.all().isEmpty)
    }

    @Test("SET-03 API 1 logic 5: a file sealed with another db_key stays; this key uses the second slot")
    func usesSecondSlotBesideAnotherKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl-\(UUID().uuidString)/pairs.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let alt = PairedDeviceStore.altURL(for: url)
        func store(_ byte: UInt8) -> PairedDeviceStore {
            PairedDeviceStore.open(fileURL: url, databaseKey: Data(repeating: byte, count: 32))
        }
        try store(7).upsert(record("first"))
        #expect(try store(8).all().isEmpty) // another build opens and leaves without pairing: nothing is written
        #expect(try store(7).active()?.pairId == "first")
        try store(8).upsert(record("second")) // the next pair saves, in the second slot
        #expect(FileManager.default.fileExists(atPath: alt.path))
        #expect(try store(7).active()?.pairId == "first")
        #expect(try store(8).active()?.pairId == "second")
        // A third key: both slots hold another key's file, so the one modified longest ago gives way.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        #expect(try store(9).all().isEmpty)
        try store(9).upsert(record("third"))
        #expect(try store(9).active()?.pairId == "third")
        #expect(try store(8).active()?.pairId == "second") // the newer of the two other keys' files was kept
        try PairedDeviceStore.deleteFiles(at: url) // SET-02 API 7: both slots
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: alt.path))
    }

    @Test("SET-03 API 1 logic 5: an error other than the key changes no slot")
    func keepsSlotsOnOtherErrors() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        // A directory where the file should be: reading fails with an I/O error, not a key mismatch.
        let directory = folder.appendingPathComponent("pairs.bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PairedDeviceStore.open(fileURL: directory, databaseKey: Data(count: 32))
        #expect(throws: (any Error).self) { try store.upsert(record("x")) }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: PairedDeviceStore.altURL(for: directory).path))
    }

    @Test("Security code: the first 8 lowercase hex of SHA-256(attestation), as on Android (PAIR-02 field 10)")
    func securityCode() throws {
        var pair = record("x")
        // The attestation of the Android PairingAuthDerivationTest; its code there is "fc647e0b".
        let hex = "484c50414952313f2b1c4d5e6f4a7b8c9d0e1f2a3b4c5d8c7d6e5f4a3b8c2d9e1f0a1b2c3d4e5f5b1f8c2e9a4d8e6f"
            + "a1b2c3d4e5f60718" + String(repeating: "33", count: 32) + String(repeating: "11", count: 32) + "000001922229940a"
        pair.attestation = Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0
        })
        #expect(pair.securityCode == "fc647e0b")
    }
}
