import HLLocalization
import SwiftUI

/// The scenes of the Mac app (03-platforms/01-macos.md): the menu bar extra, shown while "Show HandLive in Menu
/// Bar" is on (`isInserted`; removing the icon turns the setting off), and the `Settings` window. The welcome window
/// is an AppKit window of `WindowPresenter`.
public struct HandLiveScenes: Scene {
    @ObservedObject var model: AppModel
    let actions: AppActions

    public init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.showInMenuBar }, set: { model.setShowInMenuBar($0) })) {
            MenuBarMenu(model: model, actions: actions)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            SettingsView(model: model)
        }
        .commands {
            HandLiveCommands(model: model, actions: actions)
            SidebarCommands()
            TextEditingCommands()
        }
    }
}

/// HandLive's items in the app's menu bar (`.regular` mode): "Add Phone…" after "Settings…" in the HandLive menu,
/// "New Message" ⌘N in File, "Send Clipboard to Phone" after the pasteboard items of Edit (Find ⌘F comes with the
/// text editing commands), "Messages" after Minimize and Zoom in Window. Unusable items are dimmed, not hidden.
struct HandLiveCommands: Commands {
    @ObservedObject var model: AppModel
    let actions: AppActions

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button(L10n.Pairing.addPhone) { actions.showPairing() }
                .disabled(model.pairedDevice != nil)
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.Sms.newMessage) { actions.newMessage() }
                .keyboardShortcut("n")
                .disabled(!model.canComposeMessage)
        }
        CommandGroup(after: .pasteboard) {
            Button(L10n.Menu.sendClipboardToPhone) { actions.sendClipboard() }
                .disabled(!model.canSendClipboard)
        }
        CommandGroup(after: .windowSize) {
            Button(L10n.Menu.messages) { actions.showMessages() }
                .disabled(model.messages == nil)
        }
    }
}
