// Tệp sinh tự động bởi Scripts/generate-design-tokens.py từ shared/design-tokens/tokens.json.
// Không sửa tay: sửa tokens.json rồi chạy lại script (kiểm bằng --check).
import CoreGraphics

/// Thời lượng (giây); Apple ưu tiên spring của hệ thống.
public enum HLDuration {
    /// Nhấn, hover, đổi màu.
    public static let quick: Double = 0.15
    /// Công tắc, segmented, đổi trạng thái.
    public static let standard: Double = 0.25
    /// Sheet, panel, chuyển màn.
    public static let emphasized: Double = 0.4
    /// Nhịp chấm Đang kết nối và Đang phát camera.
    public static let pulse: Double = 1.5
}
