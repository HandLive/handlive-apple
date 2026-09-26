import AppKit
import HLAppCore
import HLDesignSystem
import HLLocalization
import HLTransport
import SwiftUI

/// Template symbol of the menu bar icon (MenuBarMenu README): antenna when connected or connecting, with a slash
/// otherwise; a manual clipboard send briefly shows a checkmark (Feedback).
public struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let status = model.connectionStatus
        let symbol = model.menuBarFeedback ?? status.menuBarSymbolName
        icon(symbol)
            .accessibilityLabel(Text(status.accessibilityText(deviceName: model.pairedDevice?.peerName)))
    }

    @ViewBuilder
    private func icon(_ symbol: String) -> some View {
        if #available(macOS 14, *) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace)) // Magic Replace from macOS 15, plain replace on 14
                .symbolEffect(.variableColor.iterative, isActive: model.connectionStatus == .connecting)
        } else {
            Image(systemName: symbol) // macOS 13: the icon changes without an effect
        }
    }
}

extension HLConnectionStatus {
    /// Menu bar icon (MenuBarMenu README "Biểu tượng trên thanh menu").
    var menuBarSymbolName: String {
        switch self {
        case .connectedWiFi, .connectedInternet, .usb, .connecting: "antenna.radiowaves.left.and.right"
        default: "antenna.radiowaves.left.and.right.slash"
        }
    }
}

/// Menu of the menu bar icon (MenuBarMenu): phone and status, commands, Settings and Quit.
public struct MenuBarMenu: View {
    @ObservedObject var model: AppModel
    let actions: AppActions

    public init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        if let device = model.pairedDevice {
            Text(verbatim: device.peerName)
            statusLine
            if model.link.status == .disconnected || model.connectionStatus == .needsRepair {
                Button(L10n.Status.reconnectNow) { model.reconnectNow() }
            }
        } else {
            Text(L10n.Status.notPaired)
            Button(L10n.Pairing.addPhone) { actions.showPairing() }
        }
        Divider()
        Button(L10n.Menu.sendClipboardToPhone) { actions.sendClipboard() }
            .disabled(!model.canSendClipboard)
        if let line = model.menuStatusLine {
            Text(line)
        }
        ForEach([ClipboardProgress.Direction.sending, .receiving], id: \.self) { direction in
            if let progress = model.clipboardProgress[direction] {
                Text(progress.text)
                Button(L10n.Common.cancel) { model.cancelClipboardTransfer(progress.transferId) }
            }
        }
        Divider()
        SettingsCommand()
        Button(L10n.Menu.quit) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Status row with the state's symbol in its color (a non-template image keeps its color in the menu).
    private var statusLine: some View {
        let status = model.connectionStatus
        return Label {
            Text(status.text)
        } icon: {
            Image(nsImage: StatusImage.make(status))
        }
        .accessibilityLabel(Text(status.accessibilityText(deviceName: model.pairedDevice?.peerName)))
    }
}

enum StatusImage {
    /// Colored status symbol; shapes differ per state, so the row reads without color too.
    static func make(_ status: HLConnectionStatus) -> NSImage {
        let color = NSColor(status.colorToken.color)
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: status.differentiateWithoutColorSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

/// "Settings…" ⌘, : `SettingsLink` from macOS 14; macOS 13 sends the standard action.
struct SettingsCommand: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text(L10n.Menu.settings) }
                .keyboardShortcut(",")
        } else {
            Button(L10n.Menu.settings) { SettingsOpener.open() }
                .keyboardShortcut(",")
        }
    }
}

enum SettingsOpener {
    /// The `Settings` scene from code (reopen, Dock menu). macOS 14+ ignores the `showSettingsWindow:` action, so the
    /// app menu's own "Settings…" item (⌘,) is triggered; the action is the fallback for macOS 13.
    @MainActor
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            menu.performActionForItem(at: index)
            return
        }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
