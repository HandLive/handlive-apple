import AppKit
import Foundation
import HLAppCore
import HLCrypto
import HLDesignSystem
import HLProtocol
import HLSMS
import HLSMSUI
import HLTransport

/// System lifecycle forwarded by the app delegate: sleep/wake, foreground refresh and quit (SET-03, CONN-02).
extension AppModel {
    /// Mac sleep and wake (CONN-02 E2, CLIP-02 logic 4, CLIP-05 E6), forwarded by the app delegate.
    public func systemWillSleep() async {
        clipboard?.systemWillSleep()
        await manager?.systemWillSleep()
    }

    public func systemDidWake() {
        pasteAccess = PasteAccess.current
        clipboard?.systemDidWake(pollingWanted: clipboardPollingWanted)
        Task { await manager?.systemDidWake() }
    }

    /// The app became active: re-read what the user may have changed in System Settings (SET-03 API 6 logic 3).
    public func refreshSystemState() {
        pasteAccess = PasteAccess.current
        loginItemStatus = LoginItem.status
        calls.refreshFocus()
        Task { await refreshPermissionStatuses(probeLocalNetwork: false) }
    }

    /// Settings › Permissions: re-read notifications and paste, and optionally probe Bonjour for Local Network.
    public func refreshPermissionStatuses(probeLocalNetwork: Bool) async {
        notificationPermission = await NotificationPermission.current()
        pasteAccess = PasteAccess.current
        if link.issue == .localNetworkDenied {
            localNetworkAccess = .denied
        }
        guard probeLocalNetwork else { return }
        if #available(macOS 15, *) {
            checkingPermissions = true
            defer { checkingPermissions = false }
            localNetworkAccess = LocalNetworkAccess.from(await LocalNetworkProbe.check())
        } else {
            localNetworkAccess = .notRequired
        }
    }

    /// Quit: `session/bye {shutdown}` first (CONN-02 step 8).
    public func prepareToQuit() async {
        await manager?.stop()
    }
}
