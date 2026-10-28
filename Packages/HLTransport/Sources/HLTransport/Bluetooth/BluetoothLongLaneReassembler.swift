import Foundation
import HLProtocol

/// Ghép lại làn dài của kênh điều khiển (0.4.5): một tin một lúc mỗi hướng. Đóng liên kết khi tổng byte tích luỹ
/// vượt `BT_MESSAGE_MAX` — kiểm ở MỌI mảnh, không chỉ mảnh cuối (`more` = 0): một mảnh giữa đường đã đẩy tổng
/// vượt cận phải đóng ngay, không chờ mảnh cuối đọc hết mới biết tin quá lớn.
public final class BluetoothLongLaneReassembler {
    private let messageMax: Int
    private var buffer = Data()

    public init(messageMax: Int = BtLinkConstants.messageMax) {
        self.messageMax = messageMax
    }

    /// Trả tin hoàn chỉnh khi `frame` là mảnh cuối (`more` = false), `nil` nếu còn chờ mảnh tiếp.
    public func accept(_ frame: BtTransportFrame) throws -> Data? {
        precondition(frame.long, "not a long-lane frame")
        let total = buffer.count + frame.data.count
        if total > messageMax { throw BtLinkError("long-lane message exceeds BT_MESSAGE_MAX") }
        buffer.append(frame.data)
        if frame.more { return nil }
        let result = buffer
        buffer = Data()
        return result
    }
}
