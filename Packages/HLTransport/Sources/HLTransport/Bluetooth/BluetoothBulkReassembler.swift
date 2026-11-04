import Foundation
import HLProtocol

/// Ghép lại kênh bulk `0x02` (0.4.7 bulk rule 5): một tin một lúc mỗi hướng. Đóng liên kết khi tổng byte tích luỹ
/// vượt `BT_MESSAGE_MAX` — kiểm ở MỌI mảnh, không chỉ mảnh cuối (`more` = 0): một mảnh giữa đường đã đẩy tổng
/// vượt cận phải đóng ngay, không chờ mảnh cuối đọc hết mới biết tin quá lớn.
///
/// `BtTransportFrame.decode` đã kiểm tra `dlen` ≤ `bulkFragmentMax` cho `chan` = `0x02` và `long` = 0; reassembler
/// này chỉ kiểm tổng byte tích luỹ.
public final class BluetoothBulkReassembler {
    private let messageMax: Int
    private var buffer = Data()

    public init(messageMax: Int = BtLinkConstants.messageMax) {
        self.messageMax = messageMax
    }

    /// Trả tin hoàn chỉnh khi `frame` là mảnh cuối (`more` = false), `nil` nếu còn chờ mảnh tiếp.
    public func accept(_ frame: BtTransportFrame) throws -> Data? {
        precondition(frame.chan == BtLinkConstants.chanBulk, "not a bulk frame")
        if frame.long { throw BtLinkError("long=1 on bulk channel closes the link (0.4.7 bulk rule 5)") }
        let total = buffer.count + frame.data.count
        if total > messageMax { throw BtLinkError("bulk message exceeds BT_MESSAGE_MAX") }
        buffer.append(frame.data)
        if frame.more { return nil }
        let result = buffer
        buffer = Data()
        return result
    }
}
