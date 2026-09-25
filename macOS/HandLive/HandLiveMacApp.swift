import AppKit
import HLMacUI
import SwiftUI

/// HandLive for Mac: a menu bar app (`LSUIElement`), with Settings and the welcome window (SET-03).
@main
struct HandLiveMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        HandLiveScenes(model: delegate.coordinator.model, actions: delegate.coordinator.actions)
    }
}

/// Forwards the application's life cycle to `AppCoordinator`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.didFinishLaunching()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.reopen()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await coordinator.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        coordinator.dockMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
