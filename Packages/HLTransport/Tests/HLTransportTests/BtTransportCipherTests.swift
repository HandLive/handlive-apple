import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// shared/test-vectors/bt-frame.json kind "transport_frame": nonce = 4 byte 0 ‖ bộ đếm 64-bit LE, khoá = `c1`
/// của bt-link.json (0.4.5 "Transport records and channels"). `Rekey()` không có vector riêng (`NoiseNNpsk0.rekey`)
/// — kiểm bằng cách tính thủ công khoá kỳ vọng sau rekey và so khớp với đầu ra của `BtTransportCipher`, không chỉ
/// "khác nhau".
@Suite("Bluetooth transport cipher (0.4.5, bt-frame.json)")
struct BtTransportCipherTests {
    static func c1() throws -> Data {
        let vector = try #require(VectorFile("bt-link.json").vectors
            .first { $0["kind"] as? String == "handshake" && ($0["name"] as? String)?.contains("cặp 1") == true })
        return try vector.hex("c1")
    }

    static func cipher(at vector: [String: Any]) throws -> BtTransportCipher {
        BtTransportCipher(initialKey: try Self.c1(), rekeyAfterRecords: .max, initialCounter: try vector.int("counter"))
    }

    static func transportFrameVectors() throws -> [[String: Any]] {
        try VectorFile("bt-frame.json").vectors.filter { $0["kind"] as? String == "transport_frame" }
    }

    @Test("seal matches every vector at its own counter")
    func sealMatchesVectorsAtTheirCounter() throws {
        for vector in try Self.transportFrameVectors() {
            let cipher = try Self.cipher(at: vector)
            #expect(try cipher.seal(vector.hex("plaintext")) == (try vector.hex("ciphertext_tag")), "\(vector.label)")
        }
    }

    @Test("open matches every vector at its own counter")
    func openMatchesVectorsAtTheirCounter() throws {
        for vector in try Self.transportFrameVectors() {
            let cipher = try Self.cipher(at: vector)
            #expect(try cipher.open(vector.hex("ciphertext_tag")) == (try vector.hex("plaintext")), "\(vector.label)")
        }
    }

    @Test("rekeys after the configured record count without resetting the counter")
    func rekeysAfterTheConfiguredRecordCountWithoutResettingTheCounter() throws {
        let key0 = Data((0..<32).map { UInt8($0) })
        let plaintext = Data(count: 256)
        let cipher = BtTransportCipher(initialKey: key0, rekeyAfterRecords: 2)
        _ = try cipher.seal(plaintext) // counter 0, key0
        _ = try cipher.seal(plaintext) // counter 1, key0 -> rekey triggers after this record
        let key1 = try NoiseNNpsk0.rekey(key0)
        var nonceAtCounter2 = Data(count: 12)
        nonceAtCounter2[4] = 2
        let expected = try ChaCha20Poly1305.seal(plaintext, key: key1, nonce: nonceAtCounter2, aad: Data())
        #expect(try cipher.seal(plaintext) == expected)
    }
}
