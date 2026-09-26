import AppKit
import HLLocalization
import SwiftUI

/// The app's own windows: the fixed-size welcome window (SET-03, `Onboarding`), which also hosts the pairing sheet
/// after setup (PAIR-01 step 1), the Messages window, and the way to the `Settings` scene from code.
@MainActor
public final class WindowPresenter {
    private let model: AppModel
    private var welcomeWindow: NSWindow?
    private var flow: OnboardingFlow?
    private var messagesWindow: MessagesWindowController?

    public init(model: AppModel) {
        self.model = model
    }

    /// Opens (or brings forward) the welcome window: from the first step while setup is not finished, else at the
    /// pairing step.
    public func showWelcome() {
        if let welcomeWindow, welcomeWindow.isVisible {
            if model.setupCompleted, model.pairedDevice == nil, flow?.step != .pairing {
                flow = OnboardingFlow(model: model, startAtPairing: true)
                welcomeWindow.contentViewController = hostingController()
            }
            bringForward(welcomeWindow)
            return
        }
        flow = OnboardingFlow(model: model, startAtPairing: model.setupCompleted && model.pairedDevice == nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController()
        window.center()
        welcomeWindow = window
        bringForward(window)
    }

    public func closeWelcome() {
        welcomeWindow?.close()
    }

    /// Settings › Devices and the rest (`Settings` scene).
    public func showSettings() {
        SettingsOpener.open()
    }

    /// The Messages window (SMS-03 step 1); without the SMS database (SMS-01 E7) there is nothing to show.
    public func showMessages() {
        guard let messages = model.messages else { return }
        if messagesWindow == nil { messagesWindow = MessagesWindowController(model: model, messages: messages) }
        messagesWindow?.show()
    }

    /// "New Message" (File ⌘N, the Dock menu): the Messages window with the compose screen.
    public func newMessage() {
        showMessages()
        model.messages?.startNewMessage()
    }

    private func hostingController() -> NSViewController {
        guard let flow else { return NSViewController() }
        return NSHostingController(rootView: OnboardingView(model: model, flow: flow) { [weak self] in
            self?.closeWelcome()
        })
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// In `.accessory` mode there is no menu bar, so the welcome and Settings windows close with ⌘W and Esc themselves
/// (03-platforms/01-macos.md, Activation modes). Sheets keep their own Esc (Cancel).
public enum WindowKeyMonitor {
    private static let escapeKeyCode: UInt16 = 53

    @MainActor
    public static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.activationPolicy() == .accessory, let window = NSApp.keyWindow,
                  window.styleMask.contains(.closable), !window.isSheet, window.attachedSheet == nil,
                  closes(keyCode: event.keyCode, modifiers: event.modifierFlags,
                         characters: event.charactersIgnoringModifiers)
            else { return event }
            window.performClose(nil)
            return nil
        }
    }

    /// ⌘W, or Esc without modifiers.
    static func closes(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .command, characters?.lowercased() == "w" { return true }
        return flags.isEmpty && keyCode == escapeKeyCode
    }
}
