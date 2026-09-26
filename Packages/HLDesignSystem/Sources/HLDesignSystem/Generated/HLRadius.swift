// Tệp sinh tự động bởi Scripts/generate-design-tokens.py từ shared/design-tokens/tokens.json.
// Không sửa tay: sửa tokens.json rồi chạy lại script (kiểm bằng --check).
import CoreGraphics

/// Bo góc (pt) cho control tự dựng, macOS 13–15 / iOS 16–18.
public enum HLRadius {
    /// Nút push, ô nhập trên macOS 13–15.
    public static let controlMac: CGFloat = 6
    /// Nhóm danh sách inset (iOS 16–18), vùng chọn trong sidebar.
    public static let row: CGFloat = 10
    /// Thẻ trong lớp nội dung, alert iOS 16–18.
    public static let card: CGFloat = 14
    /// Menu, popover, thông báo, panel cuộc gọi (kính).
    public static let panel: CGFloat = 18
    /// Sheet, nhóm danh sách thời Liquid Glass, cửa sổ Mac 26.
    public static let sheet: CGFloat = 26
    /// Nút capsule, công tắc, huy hiệu, thanh tab nổi.
    public static let capsule: CGFloat = 999
    /// Bo góc ô biểu tượng trong dòng GroupedList.
    public static let rowIcon: CGFloat = 8
}
