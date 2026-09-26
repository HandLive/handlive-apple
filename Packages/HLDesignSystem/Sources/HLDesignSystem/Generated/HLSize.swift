// Tệp sinh tự động bởi Scripts/generate-design-tokens.py từ shared/design-tokens/tokens.json.
// Không sửa tay: sửa tokens.json rồi chạy lại script (kiểm bằng --check).
import CoreGraphics

/// Kích thước tối thiểu và kích thước cố định (pt).
public enum HLSize {
    /// Vùng chạm mặc định iOS/iPadOS (tối thiểu size-hit-ios-min).
    public static let hitIos: CGFloat = 44
    /// Vùng chạm tối thiểu iOS/iPadOS.
    public static let hitIosMin: CGFloat = 28
    /// Control mặc định macOS (tối thiểu size-hit-mac-min).
    public static let hitMac: CGFloat = 28
    /// Control tối thiểu macOS.
    public static let hitMacMin: CGFloat = 20
    /// Vùng chạm tối thiểu Android (48 dp).
    public static let hitAndroid: CGFloat = 48
    /// Chiều cao menu bar macOS.
    public static let menuBar: CGFloat = 24
    /// Avatar chữ cái trong danh sách hội thoại (Mac 32, iOS 40).
    public static let avatar: CGFloat = 40
    /// Nút tròn Trả lời, Từ chối, Kết thúc.
    public static let callButton: CGFloat = 48
    /// Cạnh mã QR ghép nối trên Mac.
    public static let qr: CGFloat = 220
    /// Cạnh ô biểu tượng trong dòng GroupedList (iOS, Android 30 dp).
    public static let rowIcon: CGFloat = 30
}
