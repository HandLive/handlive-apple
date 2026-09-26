import Foundation
import HLAppCore
import HLLocalization
import HLTransport

extension AppModel {
    /// The clipboard engine starts with the keys (SET-03 step 2); it polls only while it has a phone and the feature is on.
    func startClipboard(identity: DeviceIdentityKeys) {
        guard clipboard == nil else { return }
        let engine = ClipboardEngine(access: pasteboard, settings: settings, deviceId: identity.deviceId,
                                     deviceName: device.name, readingAllowed: { PasteAccess.current.allowsPolling })
        engine.onNotice = { [weak self] in self?.show($0) }
        engine.onAlert = { [weak self] in self?.alerts.post($0) }
        engine.onProgress = { [weak self] direction, progress in self?.clipboardProgress[direction] = progress }
        alerts.onSendAnyway = { [weak engine] in engine?.sendAnyway() }
        alerts.onSendAgain = { [weak engine] in engine?.sendAgain() }
        clipboard = engine
        updateClipboardPolling()
    }

    /// CLIP-02: `changeCount` polling while a phone is paired and "Sync Clipboard" is on, also while disconnected (QC7).
    var clipboardPollingWanted: Bool { pairedDevice != nil && clipboardEnabled }

    func updateClipboardPolling() {
        if clipboardPollingWanted { clipboard?.startPolling() } else { clipboard?.stopPolling() }
    }

    /// "Send Clipboard to Phone" (CLIP-02 field 4).
    public func sendClipboard() {
        clipboard?.sendClipboardNow()
    }

    /// "Cancel" on a transfer's progress in the menu (CLIP-03 E6).
    public func cancelClipboardTransfer(_ transferId: String) {
        clipboard?.cancelTransfer(transferId)
    }

    /// The phone's session reached `Connected` (CONN-01 step 10): the clipboard starts and may replay (QC7).
    func clipboardConnected(_ session: ControlSession, details: LinkDetails) {
        guard let record = pairedDevice else { return }
        clipboard?.phoneConnected(peer: SessionClipboardPeer(session: session), deviceId: record.peerDeviceId,
                                  name: record.peerName, feature: details.peerCapability.features.clipboard)
    }

    /// Results in place: the status line of the menu (for two minutes) and, after a manual send, the checkmark on
    /// the menu bar icon for about a second (Feedback).
    func show(_ notice: ClipboardNotice) {
        menuStatusLine = notice.text
        statusLineReset?.cancel()
        statusLineReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ClipboardConstants.staleAfter))
            guard !Task.isCancelled else { return }
            self?.menuStatusLine = nil
        }
        guard case .sent = notice else { return }
        menuBarFeedback = "checkmark"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.menuBarFeedback = nil
        }
    }
}

extension ClipboardNotice {
    /// Text of the status line (catalog keys of CLIP-01…03).
    public var text: String {
        switch self {
        case .sent(let name): L10n.Clipboard.sentTo(deviceName: name)
        case .notConnectedWillSend: L10n.Clipboard.notConnectedWillSend
        case .emptyOrNotText: L10n.Clipboard.emptyOrNotText
        case .skippedJustReceived(let name): L10n.Clipboard.skippedJustReceived(deviceName: name)
        case .textTooLarge: L10n.Error.clipTextTooLarge
        case .imageTooLarge: L10n.Error.clipImageTooLarge
        case .imageUnreadable: L10n.Error.clipImageUnreadable
        case .writeFailedOnPhone: L10n.Error.clipWriteFailedOnPhone
        case .imageSendFailed: L10n.Error.clipImageSendFailed
        case .imageNoSpace: L10n.Error.clipImageNoSpace
        case .pasteAccessNeeded: L10n.Settings.pastePermissionHint
        case .sendFailed: L10n.Error.clipSendFailed // iPhone/iPad only
        case .unsupportedContent: L10n.Error.clipUnsupportedMime // iPhone/iPad only
        }
    }
}

extension ClipboardProgress {
    /// "Sending image to Lan's Pixel — 45%" / "Receiving image from … — 45%" (CLIP-03 field 2).
    public var text: String {
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        switch direction {
        case .sending: return L10n.Clipboard.imageSending(deviceName: deviceName, percent: percent)
        case .receiving: return L10n.Clipboard.imageReceiving(deviceName: deviceName, percent: percent)
        }
    }
}
