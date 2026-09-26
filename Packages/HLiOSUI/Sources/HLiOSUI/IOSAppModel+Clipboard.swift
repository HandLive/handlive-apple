import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLTransport

extension IOSAppModel {
    /// CLIP-04 on this device: the engine never reads the clipboard; what the user pastes is sent, what the phone
    /// sends is written with `.localOnly` and an expiration (CLIP-05).
    func startClipboard(identity: DeviceIdentityKeys) {
        let engine = ClipboardEngine(access: pasteboard, settings: settings, deviceId: identity.deviceId,
                                     deviceName: device.name, platform: .ios, readingAllowed: { false })
        engine.onNotice = { [weak self] in self?.show($0) }
        engine.onReceived = { [weak self] in self?.received = $0 }
        engine.onUnsentLocalContent = { [weak self] in self?.unsentLocalContent = $0 }
        engine.onAlert = { [weak self] alert in
            if case .conflict(let name) = alert { self?.clipboardConflict = name }
        }
        clipboard = engine
        engine.localChangeSeen()
    }

    func clipboardConnected(_ session: ControlSession, details: LinkDetails) {
        guard let record = pairedDevice else { return }
        clipboard?.phoneConnected(peer: SessionClipboardPeer(session: session), deviceId: record.peerDeviceId,
                                  name: record.peerName, feature: details.peerCapability.features.clipboard)
    }

    /// Steps 8–10: the content handed over by the system Paste button, sent at once (no permission prompt).
    public func sendPasted(_ providers: [NSItemProvider]) {
        Task {
            guard let content = await PastedContent.load(providers, imagesAllowed: settings.sendImages) else {
                return show(.unsupportedContent)
            }
            clipboard?.sendPasted(content)
        }
    }

    /// The banner's close button (CLIP-04 field 3).
    public func dismissUnsentBanner() {
        clipboard?.dismissUnsentLocalContent()
    }

    /// "Copy" on the last received card (PasteCard).
    public func copyReceivedAgain() {
        clipboard?.copyLastReceivedAgain()
    }

    /// "Send Again" after "Clipboard Not Updated on …" (CLIP-04 fields 8–9).
    public func sendAgain() {
        clipboardConflict = nil
        clipboard?.sendAgain()
    }

    public func dismissConflict() {
        clipboardConflict = nil
    }

    /// The result stays for a few seconds (Feedback README), then the card shows its normal state again.
    func show(_ notice: ClipboardNotice) {
        guard notice.iosText != nil else { return }
        clipboardNotice = notice
        noticeReset?.cancel()
        noticeReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.clipboardNotice = nil
        }
    }

    /// The card's title, "Send to Lan's Pixel 8" (CLIP-04 field 1).
    public var sendCardTitle: String? {
        pairedDevice.map { L10n.Clipboard.sendToPhoneTitle(deviceName: $0.peerName) }
    }

    /// The suggestion banner's text (field 3); `{device_type}` is "iPhone" or "iPad", never translated.
    public func unsentBannerText(deviceType: String, hasImages: Bool) -> String? {
        guard unsentLocalContent, let phone = pairedDevice?.peerName, clipboardEnabled else { return nil }
        return hasImages ? L10n.Clipboard.newImageBanner(deviceType: deviceType, deviceName: phone)
            : L10n.Clipboard.newContentBanner(deviceType: deviceType, deviceName: phone)
    }

    /// "From Lan's Pixel 8 · 2:05 PM" under the last received content.
    public func receivedCaption(_ clip: ReceivedClip) -> String {
        L10n.Clipboard.receivedFrom(deviceName: clip.deviceName,
                                    time: clip.receivedAt.formatted(date: .omitted, time: .shortened))
    }
}

extension ClipboardNotice {
    /// The iPhone and iPad wording (CLIP-04 fields 5 and 7); `nil` for results that only happen on the Mac.
    public var iosText: String? {
        switch self {
        case .sent(let name): L10n.Clipboard.sentTo(deviceName: name)
        case .notConnectedWillSend: L10n.Clipboard.notConnectedToPhone
        case .textTooLarge, .imageTooLarge: L10n.Error.clipContentTooLarge
        case .unsupportedContent, .emptyOrNotText, .imageUnreadable: L10n.Error.clipUnsupportedMime
        case .sendFailed, .writeFailedOnPhone: L10n.Error.clipSendFailed
        case .imageSendFailed: L10n.Error.clipImageSendFailed
        case .imageNoSpace: L10n.Error.clipImageNoSpace
        case .skippedJustReceived, .pasteAccessNeeded: nil
        }
    }

    /// A success shows the `Feedback` HUD and a success haptic; everything else is an error line on the card.
    public var isSuccess: Bool {
        if case .sent = self { return true }
        return false
    }
}
