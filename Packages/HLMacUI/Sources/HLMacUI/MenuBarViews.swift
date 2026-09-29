import AppKit
import HLAppCore
import HLCallNotifications
import HLDesignSystem
import HLLocalization
import HLTransport
import SwiftUI

/// Template symbol of the menu bar icon (MenuBarMenu README): antenna when connected or connecting, with a slash
/// otherwise; a manual clipboard send briefly shows a checkmark (Feedback).
public struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calls: MacCalls

    public init(model: AppModel) {
        self.model = model
        calls = model.calls
    }

    public var body: some View {
        let status = model.connectionStatus
        // A ringing call shows `phone.fill` (MenuBarMenu README).
        let symbol = calls.ringingCall != nil ? "phone.fill" : (model.menuBarFeedback ?? status.menuBarSymbolName)
        HStack(spacing: 2) {
            icon(symbol)
            if let badge = model.unreadBadgeText {
                Text(verbatim: badge).monospacedDigit() // unread conversations (MenuBarMenu README)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(calls.ringingCall.map { CallNames.incomingAnnouncement($0.caller) }
            ?? model.menuBarAccessibilityLabel))
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

/// Menu of the menu bar icon (MenuBarMenu): phone and status, a ringing call, commands, recent missed calls,
/// Settings and Quit.
public struct MenuBarMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calls: MacCalls
    let actions: AppActions

    public init(model: AppModel, actions: AppActions) {
        self.model = model
        calls = model.calls
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
        if let call = calls.ringingCall {
            RingingCallItems(call: call, calls: calls)
        }
        Divider()
        Button(L10n.Menu.sendClipboardToPhone) { actions.sendClipboard() }
            .disabled(!model.canSendClipboard)
        Button(L10n.Menu.messages) { actions.showMessages() }
            .badge(model.unreadThreads) // the unread count on the right (a menu item badge from macOS 14)
            .disabled(model.messages == nil)
        if let line = model.menuStatusLine {
            Text(line)
        }
        if !calls.recentMissed.isEmpty {
            Divider()
            ForEach(Array(calls.recentMissed.enumerated()), id: \.offset) { _, missed in
                MissedCallItem(missed: missed) { model.showCalls() }
            }
        }
        ForEach([ClipboardProgress.Direction.sending, .receiving], id: \.self) { direction in
            if let progress = model.clipboardProgress[direction] {
                Text(progress.text)
                Button(L10n.Common.cancel) { model.cancelClipboardTransfer(progress.transferId) }
            }
        }
        Divider()
        SettingsCommand(model: model)
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

/// "Settings…" ⌘,: always a `Button` so we switch to `.regular` and raise the window before the Settings scene
/// opens. `SettingsLink` inside `MenuBarExtra` never runs a simultaneous gesture, so the sheet stayed behind other
/// apps (Cursor).
struct SettingsCommand: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if #available(macOS 14, *) {
            SettingsCommandModern(model: model)
        } else {
            Button(L10n.Menu.settings) { SettingsOpener.open(model: model) }
                .keyboardShortcut(",")
        }
    }
}

@available(macOS 14, *)
private struct SettingsCommandModern: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(L10n.Menu.settings) {
            SettingsOpener.open(model: model, openSettings: openSettings)
        }
        .keyboardShortcut(",")
    }
}

enum SettingsOpener {
    /// Switch to `.regular` and activate before the Settings scene appears (menu-bar-only apps otherwise keep the
    /// window behind other apps).
    @MainActor
    static func prepareFront(model: AppModel) {
        model.settingsWindowVisibilityChanged(true)
        NSApp.activate(ignoringOtherApps: true)
        scheduleBringForward()
    }

    /// Opens Settings from a SwiftUI environment action (menu bar / ⌘,). macOS 14+.
    @available(macOS 14, *)
    @MainActor
    static func open(model: AppModel, openSettings: OpenSettingsAction) {
        prepareFront(model: model)
        openSettings()
        scheduleBringForward()
    }

    /// The `Settings` scene from AppKit (reopen, Dock menu) when the SwiftUI `openSettings` action is not in scope.
    @MainActor
    static func open(model: AppModel) {
        prepareFront(model: model)
        if let open = model.openSettingsAction {
            open()
        } else if let menu = NSApp.mainMenu?.items.first?.submenu,
                  let index = menu.items.firstIndex(where: {
                      $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
                  }) {
            menu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        scheduleBringForward()
    }

    /// Called from `SettingsView.onAppear` so a system Settings path still raises the window.
    @MainActor
    static func settingsDidAppear(model: AppModel) {
        model.settingsWindowVisibilityChanged(true)
        NSApp.activate(ignoringOtherApps: true)
        scheduleBringForward()
    }

    @MainActor
    static func settingsDidDisappear(model: AppModel) {
        model.settingsWindowVisibilityChanged(false)
    }

    @MainActor
    private static func scheduleBringForward() {
        bringSettingsForward()
        DispatchQueue.main.async { bringSettingsForward() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { bringSettingsForward() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { bringSettingsForward() }
    }

    @MainActor
    private static func bringSettingsForward() {
        for window in NSApp.windows where window.canBecomeKey && !window.className.contains("StatusBar") {
            // Settings + welcome share titled windows; skip panels (call UI).
            guard window.styleMask.contains(.titled), !(window is NSPanel) else { continue }
            // Match Pair Phone: floating + orderFrontRegardless so Cursor cannot keep covering Settings.
            window.level = .floating
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
