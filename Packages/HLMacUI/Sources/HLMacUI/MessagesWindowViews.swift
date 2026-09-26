import AppKit
import HLDesignSystem
import HLSMSUI
import SwiftUI

/// Sidebar of the Messages window: the search field at the top (⌘F), then the conversation list.
struct MessagesSidebar: View {
    @ObservedObject var messages: MessagesModel
    let search: SearchFieldHandle
    let copyNumber: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SidebarSearchField(text: $messages.searchText, handle: search)
                .padding(.horizontal, HLSpacing.space8)
                .padding(.bottom, HLSpacing.space4)
            ThreadListView(model: messages, copyNumber: copyNumber)
                .listStyle(.sidebar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right column: "New Message", the selected conversation, or nothing while no conversation is selected.
struct MessagesDetail: View {
    @ObservedObject var messages: MessagesModel

    var body: some View {
        Group {
            if let compose = messages.newMessage {
                NewMessageView(model: compose)
            } else if let selection = messages.selection {
                ConversationView(model: messages.conversation(selection)).id(selection)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sidebar's search field, which Edit › Find (⌘F) focuses.
@MainActor
final class SearchFieldHandle {
    weak var field: NSSearchField?
}

/// `NSSearchField` (the system's "Search" placeholder) bound to the conversation filter.
struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let handle: SearchFieldHandle

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        handle.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
