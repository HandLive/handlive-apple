import AppKit
import Foundation
import HLAppCore
import HLTransport

extension AppModel {
    /// "Show HandLive in Menu Bar" (SET-02 field 31): off → Dock icon and the app's own menu bar become the way in.
    /// Publishes only a change, so the menu bar extra's binding cannot feed itself.
    public func setShowInMenuBar(_ show: Bool) {
        settings.showInMenuBar = show
        if showInMenuBar != show { showInMenuBar = show }
        applyActivationPolicy()
    }

    /// `.accessory` while the menu bar icon is shown and no HandLive window is open; `.regular` (Dock, app menu
    /// bar) while Messages, Pair Phone or Settings is forward so the window can come to the front.
    public func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy =
            showInMenuBar && !messagesWindowOpen && !welcomeWindowOpen && !settingsWindowOpen
            ? .accessory : .regular
        guard let app = NSApp, app.activationPolicy() != policy else { return } // no NSApplication in unit tests
        app.setActivationPolicy(policy)
        if policy == .regular { app.activate(ignoringOtherApps: true) }
    }

    /// Welcome / Pair Phone window (PAIR-01): forces `.regular` so the sheet is not stuck behind other apps.
    public func welcomeWindowVisibilityChanged(_ open: Bool) {
        welcomeWindowOpen = open
        applyActivationPolicy()
    }

    /// Settings scene: same as Messages — Dock and menu bar while the user configures permissions.
    public func settingsWindowVisibilityChanged(_ open: Bool) {
        settingsWindowOpen = open
        applyActivationPolicy()
    }

    /// "Open HandLive at Login" (SET-02 field 22, SET-03 API 3).
    public func setOpenAtLogin(_ enabled: Bool) {
        loginItemStatus = LoginItem.set(enabled)
    }

    public func setClipboardEnabled(_ enabled: Bool) {
        settings.clipboardEnabled = enabled
        clipboardEnabled = enabled
        updateClipboardPolling()
        scheduleCapabilityUpdate()
    }

    public func setSendImages(_ enabled: Bool) {
        settings.sendImages = enabled
        sendImages = enabled
        scheduleCapabilityUpdate()
    }

    /// Local only (QC3): no capability change.
    public func setBlockSensitive(_ enabled: Bool) {
        settings.blockSensitive = enabled
        blockSensitive = enabled
    }

    /// Local only (CLIP-05): applies to clips received afterwards and re-times the pending clear (E5).
    public func setAutoClearSeconds(_ seconds: Int) {
        settings.autoClearSeconds = seconds
        autoClearSeconds = settings.autoClearSeconds
        clipboard?.autoClearSettingChanged()
    }

    /// SET-02 field 21: the capability tells the phone first, then the relay session and connection close (step 6).
    public func setRelayEnabled(_ enabled: Bool) {
        settings.relayEnabled = enabled
        relayEnabled = enabled
        relayNotice = nil
        scheduleCapabilityUpdate()
        Task { [manager] in
            try? await Task.sleep(for: .milliseconds(400)) // after the coalesced capability/update
            await manager?.setRelayEnabled(enabled)
        }
    }

    /// Several changes within 300 ms travel as one `capability/update` snapshot (SET-02 API 1 logic 2).
    func scheduleCapabilityUpdate() {
        capabilityUpdate?.cancel()
        capabilityUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await manager?.updateLocalCapability(device.capability(settings: settings))
        }
    }
}
