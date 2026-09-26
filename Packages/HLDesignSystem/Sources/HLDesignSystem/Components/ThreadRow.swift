import HLLocalization
import SwiftUI

/// One SMS conversation in the list (`ThreadRow/README.md`, SMS-03 fields 1–5): the unread dot, a letter avatar, the
/// name, the time and a two-line excerpt. Unread shows as a bold name and the dot only; the number of unread messages
/// is what VoiceOver reads (decision of 2026-09-26).
public struct ThreadRow: View {
    public enum Avatar: Equatable, Sendable {
        case initials(String)
        /// A number without a contact name.
        case unknownNumber
        case group
    }

    public struct Model: Equatable, Sendable {
        public var title: String
        public var snippet: String
        /// "2:05 PM", "Yesterday", "Sep 12" (formatted by the caller with the system formatters).
        public var time: String
        public var avatar: Avatar
        public var isUnread: Bool
        /// Unread messages on the phone, for the accessibility label.
        public var unreadCount: Int
        /// The latest message of the conversation failed to send.
        public var lastSendFailed: Bool

        public init(title: String, snippet: String, time: String, avatar: Avatar, isUnread: Bool, unreadCount: Int,
                    lastSendFailed: Bool = false) {
            self.title = title
            self.snippet = snippet
            self.time = time
            self.avatar = avatar
            self.isUnread = isUnread
            self.unreadCount = unreadCount
            self.lastSendFailed = lastSendFailed
        }
    }

    private let model: Model

    public init(_ model: Model) {
        self.model = model
    }

    #if os(macOS)
    private let avatarSide: CGFloat = 32
    private let titleStyle = HLTextStyle.macHeadline
    private let detailStyle = HLTextStyle.macSubheadline
    #else
    private let avatarSide: CGFloat = HLSize.avatar
    private let titleStyle = HLTextStyle.iosHeadline
    private let detailStyle = HLTextStyle.iosSubheadline
    #endif

    public var body: some View {
        HStack(alignment: .top, spacing: HLSpacing.space8) {
            Circle()
                .fill(model.isUnread ? Color.hl(.unread) : Color.clear)
                .frame(width: 10, height: 10)
                .padding(.top, avatarSide / 2 - 5)
            ThreadAvatar(avatar: model.avatar, side: avatarSide)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.title)
                        .hlTextStyle(titleStyle)
                        .fontWeight(model.isUnread ? .bold : .semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: HLSpacing.space4)
                    Text(model.time).hlTextStyle(detailStyle).foregroundStyle(Color.secondary)
                }
                excerpt
            }
        }
        .padding(.vertical, HLSpacing.space4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    @ViewBuilder
    private var excerpt: some View {
        if model.lastSendFailed {
            Label(L10n.Sms.statusFailed, systemImage: "exclamationmark.circle.fill")
                .hlTextStyle(detailStyle)
                .foregroundStyle(Color.hl(.destructiveText))
        } else {
            Text(model.snippet)
                .hlTextStyle(detailStyle)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
        }
    }

    private var accessibilityText: String {
        var parts = [model.title]
        if model.isUnread { parts.append(L10n.Sms.unreadCount(count: max(model.unreadCount, 1))) }
        parts.append(model.lastSendFailed ? L10n.Sms.statusFailed : model.snippet)
        parts.append(model.time)
        return parts.joined(separator: ", ")
    }
}

/// Contacts-style avatar: initials on a gray gradient, or a symbol for an unknown number or a group.
struct ThreadAvatar: View {
    let avatar: ThreadRow.Avatar
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.53)], startPoint: .top,
                                         endPoint: .bottom))
            switch avatar {
            case .initials(let text):
                Text(text).font(.system(size: side * 0.42, weight: .medium)).foregroundStyle(Color.white)
            case .unknownNumber:
                Image(systemName: "person.fill").font(.system(size: side * 0.5)).foregroundStyle(Color.white)
            case .group:
                Image(systemName: "person.2.fill").font(.system(size: side * 0.4)).foregroundStyle(Color.white)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
