// Tệp sinh tự động bởi Scripts/generate-design-tokens.py từ shared/design-tokens/tokens.json.
// Không sửa tay: sửa tokens.json rồi chạy lại script (kiểm bằng --check).
import CoreGraphics

/// Khoảng cách (pt), lưới 4 pt.
public enum HLSpacing {
    /// Khe giữa biểu tượng và chữ nhỏ.
    public static let space4: CGFloat = 4
    /// Khe giữa các phần tử trong một dòng.
    public static let space8: CGFloat = 8
    /// Đệm quanh control có viền (HIG: ~12 pt).
    public static let space12: CGFloat = 12
    /// Đệm trong thẻ, khe giữa các dòng nội dung.
    public static let space16: CGFloat = 16
    /// Lề nội dung cửa sổ Mac; khe giữa các nhóm cài đặt.
    public static let space20: CGFloat = 20
    /// Đệm quanh control không viền (HIG: ~24 pt); khe giữa hai nút tròn cuộc gọi.
    public static let space24: CGFloat = 24
    /// Khe giữa các khối lớn trên màn chào.
    public static let space32: CGFloat = 32
    /// Lề trên của tiêu đề màn chào.
    public static let space40: CGFloat = 40
    /// Lề màn hình iPhone và Android (mặc định layoutMargins compact).
    public static let marginCompact: CGFloat = 16
    /// Lề màn hình iPad và cửa sổ rộng.
    public static let marginRegular: CGFloat = 20
}
