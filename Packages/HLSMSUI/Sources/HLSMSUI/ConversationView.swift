import HLDesignSystem
import HLLocalization
import HLSMS
import HLSMSNotifications
import SwiftUI

/// A conversation (SMS-03 fields 6–12, SMS-04): day markers, bubbles oldest first, the placeholders of messages written
/// here, the history banner at the top, and the compose field (or the group note) at the bottom.
public struct ConversationView: View {
    @ObservedObject var model: ConversationModel
    /// The first unread incoming message when the conversation opened (SMS-05 field 3).
    @State private var unreadDividerKey: String?

    public init(model: ConversationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HLSpacing.space4) {
                        historyHeader.onAppear { model.reachedTop() }
                        ForEach(model.messages) { message in
                            if message.messageKey == dayStarts[message.messageKey] { dayMarker(message.ts) }
                            if message.messageKey == unreadDividerKey { unreadDivider }
                            bubble(message).id(message.messageKey)
                        }
                        ForEach(model.placeholders) { entry in placeholder(entry).id(entry.localId) }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, HLSpacing.space12)
                    .padding(.vertical, HLSpacing.space8)
                }
                .onChange(of: model.messages.count + model.placeholders.count) { _ in
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
                .onAppear {
                    unreadDividerKey = model.messages.first { $0.isIncoming && !$0.read }?.messageKey
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            footer
        }
        .navigationTitle(model.thread.map { SmsNames.title(displayName: $0.displayName, addresses: $0.addresses) } ?? "")
    }

    private static let bottom = "bottom"

    /// The first message of each day, keyed by itself.
    private var dayStarts: [String: String] {
        var starts: [String: String] = [:]
        var lastDay: Date?
        for message in model.messages {
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(message.ts) / 1000))
            if day != lastDay { starts[message.messageKey] = message.messageKey }
            lastDay = day
        }
        return starts
    }

    @ViewBuilder
    private var historyHeader: some View {
        Group {
            switch model.historyState {
            case .loading?: ProgressView().controlSize(.small).accessibilityLabel(Text(L10n.Sms.loadingOlder))
            case .complete?: Text(L10n.Sms.beginningOfConversation)
            case .needsConnection?: Text(L10n.Sms.historyNeedsConnection)
            case .threadGone?: Text(L10n.Error.smsThreadNotFound)
            case .failed?: Button(L10n.Common.retry) { model.retryHistory() }
            case .unavailable?, .ready?, nil: EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .frame(maxWidth: .infinity)
    }

    private func dayMarker(_ ts: Int64) -> some View {
        Text(SmsDisplay.dayMarker(ts))
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpacing.space8)
    }

    private var unreadDivider: some View {
        HStack {
            VStack { Divider() }
            Text(L10n.Sms.unreadDivider).font(.caption).foregroundStyle(Color.secondary)
            VStack { Divider() }
        }
    }

    private func bubble(_ message: SmsMessage) -> some View {
        let status = message.isIncoming ? nil : SmsDisplay.bubbleStatus(message.sendState, error: nil)
        let model = MessageBubble.Model(
            text: message.body, isIncoming: message.isIncoming, status: status,
            footnote: SmsDisplay.bubbleFootnote(message.ts, simLabel: self.model.engine.simLabel(for: message.subId)),
            accessibilityLabel: SmsDisplay.bubbleAccessibility(message, thread: self.model.thread, status: status))
        return MessageBubble(model)
    }

    private func placeholder(_ entry: SmsOutboxEntry) -> some View {
        let status = SmsDisplay.bubbleStatus(entry.state, error: entry.errorCode)
        let bubble = MessageBubble.Model(text: entry.body, isIncoming: false, status: status,
                                         accessibilityLabel: SmsDisplay.placeholderAccessibility(entry, status: status))
        return MessageBubble(bubble) { Task { await model.retry(localId: entry.localId) } }
    }

    @ViewBuilder
    private var footer: some View {
        if model.thread?.isGroup == true {
            Text(L10n.Sms.groupReplyOnPhone).font(.footnote).foregroundStyle(Color.secondary).padding(HLSpacing.space12)
        } else if model.engine.canSend {
            ComposeBar(text: $model.draft, subId: $model.subId, counter: model.counter, sims: model.sims,
                       canSend: model.canSend) { Task { await model.send() } }
        }
    }
}
