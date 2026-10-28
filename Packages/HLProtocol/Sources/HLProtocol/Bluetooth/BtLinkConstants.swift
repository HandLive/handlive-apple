/// Hằng số khung liên kết Bluetooth (0.4.5 "Link records", "Transport records and channels"; 0.10).
public enum BtLinkConstants {
    /// Cận trên của một bản ghi pre-auth, kiểm trước khi cấp phát (0.4.5 "Link records").
    public static let preauthRecordMax = 64

    /// `rlen` hợp lệ duy nhất của một bản ghi vận chuyển sau bước 4 (ciphertext + tag 16 byte).
    public static let transportRecordSizes = [272, 1040, 4112]

    /// Kích cỡ plaintext đã đệm trước khi mã hoá, ứng với từng giá trị của `transportRecordSizes` trừ 16 byte tag.
    public static let paddedPlaintextSizes = [256, 1024, 4096]

    /// `dlen` của làn ngắn (control, `long` = 0); cũng là cận chung của trường `dlen`.
    public static let fragmentMax = 4092

    /// `dlen` của một mảnh làn dài (control, `long` = 1) hoặc một mảnh bulk (`chan` = 0x02).
    public static let bulkFragmentMax = 1020

    /// Tổng byte lớn nhất của một tin đã ghép lại trên làn dài.
    public static let messageMax = 256 * 1024

    public static let chanControl = 0x01
    public static let chanBulk = 0x02

    /// `chan`(1) ‖ `flags`(1) ‖ `dlen`(2 BE), trước `data`.
    public static let frameHeaderSize = 4

    public static let tagSize = 16
}
