import HLLocalization
import SwiftUI

/// HandLive menu bar app. The menu bar icon opens a menu, not a popover (C19). Every user-facing text comes from
/// the string catalog through `L10n` (C20).
@main
struct HandLiveMacApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text(L10n.Status.notPaired)
            Divider()
            Button(L10n.Menu.quit) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
        }
        .menuBarExtraStyle(.menu)
    }
}
