import SwiftUI

/// Thông số của một kiểu chữ, sinh từ tokens.json (xem `HLTextStyle`).
public struct HLTextStyleSpec: Hashable, Sendable {
    public enum Family: Hashable, Sendable {
        /// Be Vietnam Pro, đóng gói trong package; chỉ cho tiêu đề thương hiệu.
        case brand
        /// SF qua text style của hệ thống; không nhúng file font.
        case system
        /// SF Mono (`design: .monospaced`).
        case monospaced
    }

    public let family: Family
    /// Cỡ mặc định (pt) — trên Apple chỉ để tham chiếu với chữ hệ thống; text style tự quyết cỡ.
    public let size: CGFloat
    public let lineHeight: CGFloat
    /// Weight dạng số CSS (400 Regular, 500 Medium, 600 Semibold, 700 Bold).
    public let weight: Int
    public let letterSpacingEm: CGFloat
    /// Text style hệ thống; với chữ thương hiệu là text style "phóng theo" (Dynamic Type).
    public let textStyle: Font.TextStyle
    /// Tên PostScript của file Be Vietnam Pro (chỉ họ `.brand`).
    public let postScriptName: String?
    /// Chữ số đều bề rộng (`fontFeatures` có `tnum` trong type-extras.json: `timer`, `code-pin`).
    public let monospacedDigit: Bool
    /// Weight khi nhấn mạnh (cột "Nhấn mạnh" của 03-kieu-chu.md), dạng số CSS.
    public let emphasisWeight: Int
    /// Be Vietnam Pro tăng một bậc weight khi người dùng bật Chữ đậm (chỉ họ `.brand`).
    public let boldTextPostScriptName: String?

    public var fontWeight: Font.Weight { Self.fontWeight(weight) }

    /// Weight SwiftUI của mức nhấn mạnh: `Text(…).fontWeight(spec.emphasisFontWeight)`.
    public var emphasisFontWeight: Font.Weight { Self.fontWeight(emphasisWeight) }

    static func fontWeight(_ cssWeight: Int) -> Font.Weight {
        switch cssWeight {
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        default: .heavy
        }
    }

    /// Tracking (pt) chỉ áp cho Be Vietnam Pro và SF Mono; SF tự chỉnh tracking theo cỡ (03-kieu-chu.md).
    public var tracking: CGFloat {
        family == .system ? 0 : letterSpacingEm * size
    }

    /// Tên PostScript dùng thật: bật Chữ đậm thì tăng một bậc (SemiBold → Bold, Bold → ExtraBold).
    public func brandPostScriptName(boldText: Bool) -> String? {
        boldText ? boldTextPostScriptName ?? postScriptName : postScriptName
    }

    /// Font SwiftUI. `boldText`: người dùng bật Chữ đậm — chữ thương hiệu tăng một bậc weight
    /// (03-kieu-chu.md); chữ hệ thống do SF tự xử lý.
    public func font(boldText: Bool = false) -> Font {
        switch family {
        case .brand:
            HLBrandFonts.registerIfNeeded()
            return Font.custom(brandPostScriptName(boldText: boldText) ?? "", size: size, relativeTo: textStyle)
        case .monospaced:
            return Font.system(textStyle, design: .monospaced).weight(fontWeight)
        case .system:
            var font = Font.system(textStyle)
            if weight != 400 { font = font.weight(fontWeight) }
            return monospacedDigit ? font.monospacedDigit() : font
        }
    }
}

extension HLTextStyle {
    public var font: Font { spec.font() }
}

private struct HLTextStyleModifier: ViewModifier {
    let style: HLTextStyle
    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        let spec = style.spec
        content
            .font(spec.font(boldText: legibilityWeight == .bold))
            .tracking(spec.tracking)
    }
}

extension View {
    /// Áp kiểu chữ HandLive: `Text("Ghép nối điện thoại").hlTextStyle(.brandTitle)`.
    public func hlTextStyle(_ style: HLTextStyle) -> some View {
        modifier(HLTextStyleModifier(style: style))
    }
}
