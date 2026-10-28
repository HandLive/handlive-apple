/// Lỗi khung liên kết Bluetooth (0.4.5 "Link records"): mọi trường hợp đóng kênh ngay, không trả lời, không nói
/// lý do qua dây (cận `rlen`/`dlen` vượt, `chan` lạ, `more` không có `long`, tin làn dài vượt `BT_MESSAGE_MAX`…).
public struct BtLinkError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}
