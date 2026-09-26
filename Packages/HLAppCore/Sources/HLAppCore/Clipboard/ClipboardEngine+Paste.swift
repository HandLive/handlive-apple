import Foundation
import HLProtocol

extension ClipboardEngine {
    // MARK: - iPhone and iPad (CLIP-04)

    /// Step 2: the scene became active or `UIPasteboard.changedNotification` fired. Only `changeCount` is read — never
    /// the content — and a change HandLive did not write marks unsent local content for the suggestion banner.
    public func localChangeSeen() {
        let count = access.changeCount
        guard count != lastSeenChangeCount else { return }
        lastSeenChangeCount = count
        settings.seenChangeCount = count
        guard count != ownWrite?.changeCount, settings.clipboardEnabled else { return }
        setUnsentLocalContent(true)
    }

    /// Steps 8–10: what the user pasted with the system Paste button goes to the phone at once. QC3 does not apply
    /// (the user sends deliberately); size and type are checked here (E3, E4, E7).
    public func sendPasted(_ content: ClipContent) {
        if case .image = content, !settings.sendImages { return onNotice(.unsupportedContent) }
        let limit = content.kind == .text ? ClipboardConstants.maxTextBytes : ClipboardConstants.maxImageBytes
        guard content.bytes.count <= limit else { return onNotice(content.kind == .text ? .textTooLarge : .imageTooLarge) }
        lastSeenChangeCount = access.changeCount
        settings.seenChangeCount = lastSeenChangeCount
        setUnsentLocalContent(false)
        send(content, sensitive: false, manual: true)
    }

    /// The banner's close button: the content stays on the clipboard, the suggestion goes.
    public func dismissUnsentLocalContent() {
        setUnsentLocalContent(false)
    }

    func setUnsentLocalContent(_ value: Bool) {
        guard unsentLocalContent != value else { return }
        unsentLocalContent = value
        onUnsentLocalContent(value)
    }

    /// E2: unsent local content and a push in the first 5 s of the session → the local content stays; the `ack` says
    /// `ignored`/`conflict` and no `clipboard/conflict` goes out.
    func keepsUnsentLocalContent() -> Bool {
        guard platform == .ios, unsentLocalContent, let start = sessionStartedAt else { return false }
        return now().timeIntervalSince(start) < ClipboardConstants.unsentLocalWindow
    }
}
