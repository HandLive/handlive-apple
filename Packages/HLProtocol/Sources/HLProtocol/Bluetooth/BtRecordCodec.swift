import Foundation

/// Bản ghi liên kết: `rlen` (uint16 BE) ‖ `rlen` byte (0.4.5 "Link records"). Người đọc phải kiểm `rlen` **trước
/// khi cấp phát** thân bản ghi (finding của pentester, review #165): `requireWithinBound`/`requireValidTransportRlen`
/// ném ngay khi vượt cận, trước khi gọi mã nào đọc thêm byte theo `rlen`.
public enum BtRecordCodec {
    public static let lengthPrefixSize = 2

    public static func encode(_ body: Data) -> Data {
        precondition(body.count <= 0xFFFF, "record body too large: \(body.count)")
        var data = Data(count: lengthPrefixSize)
        data[0] = UInt8((body.count >> 8) & 0xFF)
        data[1] = UInt8(body.count & 0xFF)
        return data + body
    }

    public static func decodeRlen(_ prefix: Data) -> Int {
        precondition(prefix.count == lengthPrefixSize, "rlen prefix must be \(lengthPrefixSize) bytes")
        let bytes = Array(prefix)
        return (Int(bytes[0]) << 8) | Int(bytes[1])
    }

    /// Bản ghi pre-auth: `rlen` vượt `maxBodySize` (`BT_PREAUTH_RECORD_MAX`) → đóng kênh, không đọc thêm.
    public static func requireWithinBound(_ rlen: Int, maxBodySize: Int) throws {
        if rlen > maxBodySize { throw BtLinkError("rlen \(rlen) exceeds bound \(maxBodySize)") }
    }

    /// Bản ghi vận chuyển: `rlen` phải đúng một trong ba cỡ cố định, không chỉ ≤ cận trên (0.4.5).
    public static func requireValidTransportRlen(_ rlen: Int) throws {
        guard BtLinkConstants.transportRecordSizes.contains(rlen) else {
            throw BtLinkError("rlen \(rlen) is not a valid transport record size")
        }
    }
}
