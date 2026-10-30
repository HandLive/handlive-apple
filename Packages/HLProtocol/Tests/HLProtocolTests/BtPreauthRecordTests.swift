import Foundation
import Testing
@testable import HLProtocol

/// shared/test-vectors/bt-frame.json kind "preauth_frame": thân pre-auth = kind(1) ‖ payload (0.4.5 "Link
/// records" bảng).
@Suite("Bluetooth pre-auth records (0.4.5, bt-frame.json)")
struct BtPreauthRecordTests {
    static func vectors() throws -> [[String: Any]] {
        try VectorFile("bt-frame.json").vectors.filter { $0["kind"] as? String == "preauth_frame" }
    }

    @Test("encode/decode of challenge and reject match the vectors")
    func encodeAndDecodeMatchVectors() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 2)
        for vector in vectors {
            let kind = try Int(parsingHex: vector.string("preauth_kind"))
            let body = try vector.hex("body")
            let payload = body.dropFirst()
            #expect(BtPreauthRecord.encode(kind: kind, payload: Data(payload)) == body, "\(vector.label)")
            let decoded = try BtPreauthRecord.decode(body)
            #expect(decoded.kind == kind, "\(vector.label)")
            #expect(decoded.payload == Data(payload), "\(vector.label)")
        }
    }

    @Test("an empty body is rejected")
    func emptyBodyIsRejected() {
        #expect(throws: BtLinkError.self) { try BtPreauthRecord.decode(Data()) }
    }

    @Test("kind constants match the vectors")
    func kindConstantsMatchVectors() {
        #expect(BtPreauthRecord.kindChallenge == 0x01)
        #expect(BtPreauthRecord.kindReject == 0x7F)
        #expect(BtPreauthRecord.kindNoise1 == 0x02)
        #expect(BtPreauthRecord.kindNoise2 == 0x03)
    }
}

extension Int {
    /// Parses `"0x01"`-style hex literals from the shared test vectors.
    init(parsingHex text: String) throws {
        guard text.hasPrefix("0x"), let value = Int(text.dropFirst(2), radix: 16) else {
            throw VectorError.badHex(text)
        }
        self = value
    }
}
