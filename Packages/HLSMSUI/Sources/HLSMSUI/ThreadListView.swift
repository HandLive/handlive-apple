import HLDesignSystem
import HLLocalization
import HLSMS
import SwiftUI

/// The conversation list (SMS-03 fields 1–5, SMS-01 fields 1–2): the sync banner above `ThreadRow`s sorted by the
/// latest message, the empty state, and the row actions ("Mark as Read", "Copy Number").
public struct ThreadListView: View {
    @ObservedObject var model: MessagesModel
    /// "Copy Number" (Mac context menu): the platform's pasteboard.
    let copyNumber: (String) -> Void

    public init(model: MessagesModel, copyNumber: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.copyNumber = copyNumber
    }

    public var body: some View {
        List(selection: $model.selection) {
            if let banner = SmsDisplay.syncBanner(model.syncStatus) {
                Text(banner).font(.footnote).foregroundStyle(Color.secondary)
            }
            if model.threads.isEmpty {
                emptyState
            }
            ForEach(model.visibleThreads) { thread in
                ThreadRow(SmsDisplay.row(thread, lastSendFailed: model.failedThreads.contains(thread.threadId)))
                    .tag(thread.threadId)
                    .contextMenu { rowActions(thread) }
                    #if os(iOS)
                    .swipeActions(edge: .leading) {
                        Button(L10n.Sms.markAsRead) { markRead(thread) }.tint(Color.hl(.accentFill))
                    }
                    #endif
                    .onAppear { if thread.threadId == model.threads.last?.threadId { model.loadMoreThreads() } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: HLSpacing.space8) {
            Image(systemName: "message").font(.largeTitle).foregroundStyle(Color.secondary)
            Text(L10n.Sms.emptyTitle).font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpacing.space40)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rowActions(_ thread: SmsThread) -> some View {
        if thread.isUnread { Button(L10n.Sms.markAsRead) { markRead(thread) } }
        if !thread.isGroup, let address = thread.addresses.first {
            Button(L10n.Sms.copyNumber) { copyNumber(address) }
        }
    }

    private func markRead(_ thread: SmsThread) {
        Task { await model.engine.markAsRead(threadId: thread.threadId) }
    }
}

extension SmsDisplay {
    /// SMS-01 field 1: "Syncing messages…" (with the count of the first sync), or "Couldn't sync — will try again when
    /// connected"; nothing when idle or done.
    public static func syncBanner(_ status: SmsSyncStatus) -> String? {
        switch status {
        case .syncing(let downloaded, let firstSync) where firstSync && downloaded > 0:
            L10n.Sms.syncDownloaded(count: downloaded)
        case .syncing: L10n.Sms.syncing
        case .failed(.interrupted), .failed(.phoneError), .failed(.storage): L10n.Sms.syncFailed
        case .failed(.permissionMissing): L10n.Pairing.reasonMissingSmsPermission
        case .idle, .done, .failed(.featureOff): nil
        }
    }
}
