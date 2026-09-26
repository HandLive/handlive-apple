import HLLocalization
import SwiftUI

/// Kiểu nút theo `docs/design-system/components/Button/README.md`: dùng kiểu nút của hệ thống,
/// tô bằng token. Vai trò (chính, hủy, phá hủy) đặt trên `Button(role:)` và `.keyboardShortcut`.
public enum HLButtonStyle: Sendable, CaseIterable {
    /// Hành động chính của màn, tối đa một: `.borderedProminent` (từ 26: `.glassProminent`), `accent-fill`.
    case prominent
    /// Hành động phụ cạnh nút chính: `.bordered` (từ 26: `.glass`).
    case glass
    /// Nên thấy nhưng không phải chính ("Mở cài đặt"): `.bordered` + `.tint(.accentColor)`.
    case tinted
    /// Liên kết, lệnh phụ trong câu: `.borderless`, màu nhấn.
    case plain
    /// Hủy ghép nối, xóa lịch sử: `.bordered`, chữ `destructive-text`. Gọi kèm `Button(role: .destructive)`.
    case destructive
}

extension View {
    /// `Button("Ghép nối") { … }.hlButtonStyle(.prominent)`.
    public func hlButtonStyle(_ style: HLButtonStyle) -> some View {
        modifier(HLButtonStyleModifier(style: style))
    }
}

private struct HLButtonStyleModifier: ViewModifier {
    let style: HLButtonStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        styled(content).platformSizing(prominent: style == .prominent)
    }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        switch style {
        case .prominent:
            #if os(macOS)
            // macOS: nút chính theo Màu nhấn người dùng chọn (01-mau-sac.md: không ép xanh lá);
            // khi người dùng để "Nhiều màu", hệ thống lấy AccentColor = accent.
            prominentBase(content)
            #else
            prominentBase(content).tint(token(.accentFill))
            #endif
        case .glass:
            glassBase(content)
        case .tinted:
            content.buttonStyle(.bordered).tint(.accentColor)
        case .plain:
            content.buttonStyle(.borderless).foregroundStyle(Color.accentColor)
        case .destructive:
            content.buttonStyle(.bordered).foregroundStyle(token(.destructiveText))
        }
    }

    @ViewBuilder
    private func prominentBase(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
        #else
        content.buttonStyle(.borderedProminent)
        #endif
    }

    @ViewBuilder
    private func glassBase(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, iOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        content.buttonStyle(.bordered)
        #endif
    }

    private func token(_ token: HLColorToken) -> Color {
        token.resolved(colorScheme: colorScheme, contrast: contrast)
    }
}

private extension View {
    /// iOS/iPadOS: capsule, nút chính `.large` (cao 50 pt). macOS giữ `.regular` của form và sheet;
    /// nút cuối cửa sổ chào tự đặt `.controlSize(.large)`.
    @ViewBuilder
    func platformSizing(prominent: Bool) -> some View {
        #if os(iOS)
        buttonBorderShape(.capsule).controlSize(prominent ? .large : .regular)
        #else
        self
        #endif
    }
}

/// Preview sample: labels from the string catalog.
struct HLButtonStylePreviewGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpacing.space12) {
            Button(L10n.Pairing.addPhone) {}.hlButtonStyle(.prominent)
            Button(L10n.Menu.settings) {}.hlButtonStyle(.glass)
            Button(L10n.Common.openSystemSettings) {}.hlButtonStyle(.tinted)
            Button(L10n.Menu.sendClipboardToPhone) {}.hlButtonStyle(.plain)
            Button(L10n.Pairing.unpairEllipsis, role: .destructive) {}.hlButtonStyle(.destructive)
            // In progress: the label turns into progress with a small ProgressView; the button keeps its size.
            Button {} label: {
                HStack(spacing: HLSpacing.space8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Pairing.inProgress)
                }
            }
            .hlButtonStyle(.prominent)
        }
    }
}

#if !HL_COMMAND_LINE_TOOLS_ONLY
#Preview("Light") { HLButtonStylePreviewGallery().hlPreviewAppearance(.light) }
#Preview("Dark") { HLButtonStylePreviewGallery().hlPreviewAppearance(.dark) }
#Preview("Light · High Contrast") { HLButtonStylePreviewGallery().hlPreviewAppearance(.lightHighContrast) }
#Preview("Dark · High Contrast") { HLButtonStylePreviewGallery().hlPreviewAppearance(.darkHighContrast) }
#endif
