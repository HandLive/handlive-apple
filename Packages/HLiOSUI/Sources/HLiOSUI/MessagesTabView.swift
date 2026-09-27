#if os(iOS)
import HLDesignSystem
import HLLocalization
import HLSMSUI
import SwiftUI

/// The Messages tab (02-ios-ipados.md; SMS-01…05): a `NavigationSplitView` — the list and the conversation side by
/// side in regular width (iPad, the inner display of iPhone Duo), one column in compact width — with search, the
/// "All / Unread" filter, "New Message" in the toolbar as a sheet, and swipe to mark as read.
struct MessagesTabView: View {
    @ObservedObject var model: IOSAppModel

    var body: some View {
        if let messages = model.messages {
            MessagesSplitView(messages: messages)
        } else {
            NavigationStack {
                Label(L10n.Error.smsSyncStorage, systemImage: "exclamationmark.triangle") // SMS-01 E7
                    .foregroundStyle(Color.secondary)
                    .padding(HLSpacing.space24)
                    .navigationTitle(L10n.Sms.title)
            }
        }
    }
}

struct MessagesSplitView: View {
    @ObservedObject var messages: MessagesModel
    @State private var composing = false

    var body: some View {
        NavigationSplitView {
            ThreadListView(model: messages)
                .listStyle(.plain)
                .safeAreaInset(edge: .top) { filter }
                .searchable(text: $messages.searchText)
                .navigationTitle(L10n.Sms.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            messages.startNewMessage()
                            composing = messages.newMessage != nil
                        } label: {
                            Label(L10n.Sms.newMessage, systemImage: "square.and.pencil")
                        }
                        .keyboardShortcut("n")
                        .disabled(messages.pairId == nil)
                    }
                }
        } detail: {
            if let selection = messages.selection {
                ConversationView(model: messages.conversation(selection))
                    .id(selection)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                Color.clear
            }
        }
        .sheet(isPresented: $composing, onDismiss: messages.closeNewMessage) {
            if let compose = messages.newMessage {
                NavigationStack {
                    NewMessageView(model: compose)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.Common.cancel) { composing = false }
                            }
                        }
                }
                .presentationDetents([.large])
            }
        }
        .onReceive(messages.$newMessage) { compose in
            if compose == nil { composing = false } // the phone's copy opened the new conversation (SMS-04 step 11)
        }
    }

    /// "All / Unread" above the list (SMS-03, iPhone and iPad).
    private var filter: some View {
        Picker(selection: $messages.unreadOnly) {
            Text(L10n.Sms.filterAll).tag(false)
            Text(L10n.Sms.filterUnread).tag(true)
        } label: {
            Text(L10n.Sms.filterUnread)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, HLSpacing.space16)
        .padding(.vertical, HLSpacing.space8)
        .background(.bar)
    }
}
#endif
