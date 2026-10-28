/// Hằng số phiên liên kết Bluetooth phía C/M-APP (0.10): rekey, lập lịch — khác hằng số khung của `HLProtocol`.
/// Không có cận admission (`BT_LINK_LIMIT`, `BT_PREAUTH_LIMIT`, `BT_AUTH_FAIL_BLOCK`…): đó là việc của A-SVC
/// (điện thoại, A7.1b), không áp dụng cho phía gọi ra.
public enum BluetoothLinkConstants {
    /// Noise `Rekey()` trên CipherState gửi sau mỗi bao nhiêu bản ghi một chiều.
    public static let linkRekeyRecords: Int64 = 65_536

    /// Số bản ghi làn dài + bulk cùng lúc đã gửi mà chưa xả (0.4.5 "Priority").
    public static let bulkInflight = 2
}
