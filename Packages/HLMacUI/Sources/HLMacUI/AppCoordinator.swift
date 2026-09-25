import AppKit
import Foundation
import HLLocalization

/// App-level glue the app delegate forwards to: launch (SET-03 step 1–2), reopen, sleep and wake (CONN-02 E2),
/// quitting (CONN-02 step 8) and the Dock menu of `.regular` mode.
@MainActor
public final class AppCoordinator {
    public let model: AppModel
    public let windows: WindowPresenter
    /// Sends the clipboard on "Send Clipboard to Phone"; set by the clipboard module.
    public var sendClipboard: () -> Void = {}
    private var observers: [NSObjectProtocol] = []

    public init(model: AppModel = AppModel()) {
        self.model = model
        windows = WindowPresenter(model: model)
    }

    public var actions: AppActions {
        AppActions(showPairing: { [weak self] in self?.windows.showWelcome() },
                   showOnboarding: { [weak self] in self?.windows.showWelcome() },
                   sendClipboard: { [weak self] in self?.sendClipboard() })
    }

    /// Step 1: the menu bar icon exists from launch; the welcome window opens while setup is not done or the keys
    /// failed; the old copy is trashed after a move to /Applications.
    public func didFinishLaunching(arguments: [String] = ProcessInfo.processInfo.arguments) {
        ApplicationLocation.removeMovedFromCopy(arguments: arguments)
        WindowKeyMonitor.install()
        model.launch()
        model.applyActivationPolicy()
        observeSystem()
        if !model.setupCompleted || model.phase == .keysFailed { windows.showWelcome() }
    }

    /// Opening HandLive again from Finder, Launchpad or Spotlight: the welcome window while no phone is paired, else
    /// Settings (Phase 1 has no Messages window yet).
    public func reopen() {
        if !model.setupCompleted || model.pairedDevice == nil || model.phase != .ready {
            windows.showWelcome()
        } else {
            windows.showSettings()
        }
    }

    /// `session/bye {shutdown}` before the app quits, at most two seconds.
    public func prepareToQuit() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.model.prepareToQuit() }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Dock menu (`.regular` mode): the menu bar commands, for when the icon is hidden.
    public func dockMenu() -> NSMenu {
        let menu = NSMenu()
        if model.pairedDevice == nil {
            menu.addItem(ClosureMenuItem(title: L10n.Pairing.addPhone) { [weak self] in self?.windows.showWelcome() })
        }
        let send = ClosureMenuItem(title: L10n.Menu.sendClipboardToPhone) { [weak self] in self?.sendClipboard() }
        send.isEnabled = model.canSendClipboard
        menu.autoenablesItems = false
        menu.addItem(send)
        return menu
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.systemWillSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.systemDidWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.refreshSystemState() }
        })
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func run() {
        handler()
    }
}
