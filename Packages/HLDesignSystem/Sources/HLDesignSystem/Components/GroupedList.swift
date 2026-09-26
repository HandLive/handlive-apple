import HLLocalization
import SwiftUI

/// Danh sách nhóm kiểu Cài đặt (`GroupedList/README.md`): iOS/iPadOS `List` `.insetGrouped`,
/// macOS `Form` `.grouped`. Nền, góc bo đồng tâm và đường phân cách do hệ thống vẽ.
public struct GroupedList<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        #if os(macOS)
        Form { content }.formStyle(.grouped)
        #else
        List { content }.listStyle(.insetGrouped)
        #endif
    }
}

/// Một nhóm: tiêu đề sentence case (không viết hoa toàn bộ — `.textCase(nil)` cho iOS 16–18),
/// chú thích là câu hoàn chỉnh giải thích hệ quả.
public struct GroupedSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        Section {
            content
        } header: {
            if let title {
                Text(title).textCase(nil).foregroundStyle(Color.secondary)
                #if os(iOS)
                    .font(.footnote.weight(.semibold)) // 13 pt Semibold, phóng theo Dynamic Type
                #endif
            }
        } footer: {
            if let footer { Text(footer).foregroundStyle(Color.secondary) }
        }
    }
}

/// Nhóm chức năng quyết định màu ô biểu tượng (tránh xanh dương — Thủy khắc Hỏa).
public enum HLFeatureGroup: Sendable, CaseIterable {
    case devices, clipboard, messages, calls, notifications, internet

    public var colorToken: HLColorToken {
        switch self {
        case .devices: .systemGray
        case .clipboard: .systemOrange
        case .messages: .systemGreen
        case .calls: .callAcceptFill
        case .notifications: .systemRed
        case .internet: .systemPurple
        }
    }
}

/// Nhãn dòng: ô biểu tượng vuông 30 pt bo 8 pt, glyph trắng trên màu nhóm; tiêu đề; lý do chưa dùng được
/// (`text-orange`, có biểu tượng thông tin) ngay dưới tiêu đề. Dùng làm nhãn cho `Toggle`, `NavigationLink`,
/// `LabeledContent` để hệ thống lo giá trị và mũi tên.
public struct GroupedRowLabel: View {
    private static let iconSide: CGFloat = 30 // GroupedList/README.md: "biểu tượng vuông 30 pt bo 8 pt"
    private static let iconRadius: CGFloat = 8

    private let title: String
    private let systemImage: String?
    private let feature: HLFeatureGroup?
    private let unavailableReason: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ title: String, systemImage: String? = nil, feature: HLFeatureGroup? = nil,
                unavailableReason: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.feature = feature
        self.unavailableReason = unavailableReason
    }

    public var body: some View {
        HStack(spacing: HLSpacing.space12) {
            if let systemImage, let feature {
                Image(systemName: systemImage)
                    .foregroundStyle(color(.onAccent))
                    .frame(width: Self.iconSide, height: Self.iconSide)
                    .background(color(feature.colorToken),
                                in: RoundedRectangle(cornerRadius: Self.iconRadius, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: HLSpacing.space4) {
                Text(title)
                if let unavailableReason {
                    Label(unavailableReason, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(color(.textOrange))
                }
            }
        }
    }

    private func color(_ token: HLColorToken) -> Color {
        token.resolved(colorScheme: colorScheme, contrast: contrast)
    }
}

/// Dòng hành động (chữ `accent`) hoặc phá hủy (chữ `destructive-text`, luôn ở nhóm cuối; `action` phải
/// hỏi xác nhận bằng `Alert` trước khi làm).
public struct GroupedActionRow: View {
    private let title: String
    private let role: ButtonRole?
    private let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(title, role: role, action: action)
            .buttonStyle(.borderless)
            .foregroundStyle(role == .destructive
                ? HLColorToken.destructiveText.resolved(colorScheme: colorScheme, contrast: contrast)
                : Color.accentColor)
    }
}

/// Preview sample: the Clipboard pane of the Mac Settings (2-patterns/04-cai-dat.md), labels from the catalog.
struct GroupedListPreviewGallery: View {
    var body: some View {
        GroupedList {
            GroupedSection(L10n.Settings.clipboard, footer: L10n.Settings.autoClearFooter) {
                Toggle(isOn: .constant(true)) {
                    GroupedRowLabel(L10n.Settings.syncClipboard, systemImage: "doc.on.clipboard", feature: .clipboard)
                }
                Toggle(isOn: .constant(false)) { GroupedRowLabel(L10n.Settings.syncImages) }
                Toggle(isOn: .constant(true)) {
                    GroupedRowLabel(L10n.Settings.blockSensitive,
                                    unavailableReason: L10n.Pairing.reasonMissingPermission)
                }
                .disabled(true)
            }
            GroupedSection(L10n.Settings.pasteFromOtherApps, footer: L10n.Settings.pastePermissionHint) {
                GroupedActionRow(L10n.Common.openSystemSettings) {}
            }
            GroupedSection {
                GroupedActionRow(L10n.Pairing.unpairEllipsis, role: .destructive) {}
            }
        }
        .frame(minHeight: 420)
    }
}

#if !HL_COMMAND_LINE_TOOLS_ONLY
#Preview("Light") { GroupedListPreviewGallery().hlPreviewAppearance(.light) }
#Preview("Dark") { GroupedListPreviewGallery().hlPreviewAppearance(.dark) }
#Preview("Light · High Contrast") { GroupedListPreviewGallery().hlPreviewAppearance(.lightHighContrast) }
#Preview("Dark · High Contrast") { GroupedListPreviewGallery().hlPreviewAppearance(.darkHighContrast) }
#endif
