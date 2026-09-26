import AppKit
import Combine
import HLLocalization
import HLSMSNotifications
import HLSMSUI
import SwiftUI

/// The Messages window (03-platforms/01-macos.md): the conversations in the sidebar with the search field at its top,
/// the conversation or "New Message" on the right, "New Message" in the toolbar. An AppKit window hosting the SwiftUI
/// screens, like the welcome window, so it opens only when asked (menus, a notification, the Dock, reopening) and
/// never by itself at launch; while it is open the app has its Dock icon and menu bar (`.regular`).
@MainActor
final class MessagesWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSToolbarItemValidation {
    private static let newMessageItem = NSToolbarItem.Identifier("app.handlive.messages.new-message")
    private static let frameName = "HandLiveMessages"
    private let model: AppModel
    let messages: MessagesModel
    private let search = SearchFieldHandle()
    private var titleUpdates: AnyCancellable?

    init(model: AppModel, messages: MessagesModel) {
        self.model = model
        self.messages = messages
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.Sms.title
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentViewController = splitView()
        let toolbar = NSToolbar(identifier: "HandLiveMessagesToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName) // the frame comes back on the next opening
        titleUpdates = messages.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSubtitle() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Brings the window forward; the Dock icon and the app menu bar come with it.
    func show() {
        guard let window else { return }
        model.messagesWindowVisibilityChanged(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateSubtitle()
    }

    private func splitView() -> NSSplitViewController {
        let split = NSSplitViewController()
        let sidebarView = MessagesSidebar(messages: messages, search: search) { number in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(number, forType: .string)
        }
        let sidebarHost = NSHostingController(rootView: sidebarView)
        sidebarHost.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.minimumThickness = 240
        sidebar.maximumThickness = 420
        sidebar.canCollapse = true
        let detailHost = NSHostingController(rootView: MessagesDetail(messages: messages))
        detailHost.sizingOptions = []
        let detail = NSSplitViewItem(viewController: detailHost)
        detail.minimumThickness = 380
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(detail)
        split.splitView.autosaveName = "HandLiveMessagesSplit"
        return split
    }

    /// The conversation's name (or "New Message") under the window title.
    private func updateSubtitle() {
        guard let window else { return }
        if messages.newMessage != nil {
            window.subtitle = L10n.Sms.newMessage
        } else if let thread = messages.threads.first(where: { $0.threadId == messages.selection }) {
            window.subtitle = SmsNames.title(displayName: thread.displayName, addresses: thread.addresses)
        } else {
            window.subtitle = ""
        }
    }

    // MARK: - Commands

    /// "New Message" (toolbar, File ⌘N, Dock menu).
    @objc func newMessage(_ sender: Any?) {
        messages.startNewMessage()
    }

    /// Edit › Find ⌘F puts the cursor in the search field at the top of the sidebar.
    @objc func performFindPanelAction(_ sender: Any?) {
        focusSearch()
    }

    override func performTextFinderAction(_ sender: Any?) {
        focusSearch()
    }

    private func focusSearch() {
        guard let field = search.field else { return }
        window?.makeFirstResponder(field)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier != Self.newMessageItem || messages.pairId != nil
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        messages.setActive(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        messages.setActive(false)
    }

    func windowWillClose(_ notification: Notification) {
        messages.setActive(false)
        model.messagesWindowVisibilityChanged(false)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.newMessageItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.newMessageItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = L10n.Sms.newMessage
        item.toolTip = L10n.Sms.newMessage
        item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: L10n.Sms.newMessage)
        item.isBordered = true
        item.target = self
        item.action = #selector(newMessage(_:))
        return item
    }
}
