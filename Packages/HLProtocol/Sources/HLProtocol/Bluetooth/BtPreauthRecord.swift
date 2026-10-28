import Foundation

/// Thân bản ghi pre-auth, plaintext, byte đầu = kind (0.4.5 "Link records" bảng).
public enum BtPreauthRecord {
    public static let kindChallenge = 0x01
    public static let kindNoise1 = 0x02
    public static let kindNoise2 = 0x03
    public static let kindCpace1 = 0x04
    public static let kindCpace2 = 0x05
    public static let kindReject = 0x7F

    public struct Decoded: Equatable, Sendable {
        public let kind: Int
        public let payload: Data
    }

    public static func encode(kind: Int, payload: Data = Data()) -> Data {
        Data([UInt8(kind)]) + payload
    }

    /// `body` đã qua `BtRecordCodec.requireWithinBound`; thân rỗng (không cả byte kind) → đóng kênh.
    public static func decode(_ body: Data) throws -> Decoded {
        guard let first = body.first else { throw BtLinkError("empty pre-auth record") }
        return Decoded(kind: Int(first), payload: body.dropFirst())
    }
}
