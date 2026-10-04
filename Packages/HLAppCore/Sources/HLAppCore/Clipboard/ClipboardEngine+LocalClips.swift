import Foundation
import HLProtocol
import HLTransport

extension ClipboardEngine {
    // MARK: - Local clips (CLIP-02 steps 3–8, CLIP-03 steps 2–5)

    /// `poll()` and `sendClipboardNow()` start here.
    func capture(manual: Bool) {
        let clip = LocalClipReader.read(access)
        switch clip {
        case .ownWrite:
            // What is on the clipboard came from the phone: never sent back (QC4).
            detectedLocalChange = nil
            if manual, let phone { onNotice(.skippedJustReceived(deviceName: phone.name)) }
        case .unsupported:
            detectedLocalChange = nil
            readFailed("empty_or_not_text", manual: manual, types: true)
            if manual { onNotice(.emptyOrNotText) }
        case .text(let text, let sensitiveType):
            captureText(text, sensitiveType: sensitiveType, manual: manual)
        case .image, .imageFile:
            captureImageClip(clip, manual: manual)
        }
    }

    /// Images (CLIP-03): normalized, and a copied image file read, off the main actor. `clip.send_images` off (E1):
    /// nothing is sent; the manual path says there is nothing to send.
    private func captureImageClip(_ clip: LocalClip, manual: Bool) {
        guard settings.sendImages else {
            detectedLocalChange = nil
            readFailed("images_off", manual: manual)
            if manual { onNotice(.emptyOrNotText) }
            return
        }
        Task {
            switch clip {
            case .image(let data, let type, let sensitiveType):
                captureImage(await Self.normalized(data, typeIdentifier: type), sensitiveType: sensitiveType, manual: manual)
            case .imageFile(let url, let type, let sensitiveType):
                await captureImageFile(url, typeIdentifier: type, sensitiveType: sensitiveType, manual: manual)
            default:
                break
            }
        }
    }

    /// An image file copied in Finder (CLIP-03 API 2 logic 5): read off the main actor, only within `CLIP_MAX_IMAGE`.
    private func captureImageFile(_ url: URL, typeIdentifier: String, sensitiveType: Bool, manual: Bool) async {
        let file = await Task.detached(priority: .userInitiated) { LocalClipReader.readImageFile(url) }.value
        guard case .data(let data) = file else {
            detectedLocalChange = nil
            readFailed(file == .tooLarge ? "image_too_large" : "image_unreadable", manual: manual, stage: "file")
            if file == .tooLarge { onNotice(.imageTooLarge) } else if manual { onNotice(.imageUnreadable) }
            return
        }
        captureImage(await Self.normalized(data, typeIdentifier: typeIdentifier), sensitiveType: sensitiveType,
                     manual: manual)
    }

    private static func normalized(_ data: Data, typeIdentifier: String) async -> ClipImage? {
        await Task.detached(priority: .userInitiated) { ImageNormalizer.normalize(data, typeIdentifier: typeIdentifier) }
            .value
    }

    private func captureText(_ text: String, sensitiveType: Bool, manual: Bool) {
        detectedLocalChange = nil
        let content = ClipContent.text(text)
        if let received, received.sha256 == content.sha256,
           now().timeIntervalSince(received.at) < ClipboardConstants.loopWindow {
            if manual, let phone { onNotice(.skippedJustReceived(deviceName: phone.name)) }
            return
        }
        if !manual, echoesLatestLocal(content) { return }
        if settings.blockSensitive, sensitiveType || SensitiveContent.looksLikeCardNumber(text) {
            hold(content, as: .sensitiveBlocked)
            return
        }
        guard content.bytes.count <= ClipboardConstants.maxTextBytes else {
            onNotice(.textTooLarge)
            return
        }
        send(content, sensitive: false, manual: manual)
    }

    private func captureImage(_ image: ClipImage?, sensitiveType: Bool, manual: Bool) {
        detectedLocalChange = nil
        guard let image else {
            readFailed("image_unreadable", manual: manual, stage: "normalize")
            if manual { onNotice(.imageUnreadable) }
            return
        }
        guard image.data.count <= ClipboardConstants.maxImageBytes else {
            readFailed("image_too_large", manual: manual, stage: "normalize")
            onNotice(.imageTooLarge)
            return
        }
        let content = ClipContent.image(image)
        if let received, received.sha256 == content.sha256,
           now().timeIntervalSince(received.at) < ClipboardConstants.loopWindow { return }
        if !manual, echoesLatestLocal(content) { return }
        if settings.blockSensitive, sensitiveType {
            hold(content, as: .sensitiveBlocked)
            return
        }
        send(content, sensitive: false, manual: manual)
    }

    /// The clip this device just sent came back as a new change: another clipboard tool (an emulator's clipboard
    /// sharing, Universal Clipboard, a clipboard manager) wrote it again once the phone had it. Sending it once more
    /// would loop (QC4). The echo can overtake the phone's ack, so a clip not acknowledged yet (in flight, or kept for
    /// replay) counts too; an applied one for `CLIP_LOOP_WINDOW` after the ack.
    private func echoesLatestLocal(_ content: ClipContent) -> Bool {
        guard let latestLocal, latestLocal.content.sha256 == content.sha256 else { return false }
        if let appliedAt = latestLocal.appliedAt {
            return now().timeIntervalSince(appliedAt) < ClipboardConstants.loopWindow
        }
        return !latestLocal.acknowledged
            && now().timeIntervalSince(latestLocal.createdAt) <= ClipboardConstants.staleAfter
    }

    private func hold(_ content: ClipContent, as alert: ClipboardAlert) {
        heldSensitive = HeldClip(content: content, sensitive: true, heldAt: now())
        onAlert(alert)
    }

    /// "Send Anyway" on the sensitive-content notification: sends with `sensitive = true` within 120 s (QC3).
    public func sendAnyway() {
        guard let held = heldSensitive, now().timeIntervalSince(held.heldAt) <= ClipboardConstants.staleAfter else {
            heldSensitive = nil
            return
        }
        heldSensitive = nil
        send(held.content, sensitive: true, manual: true)
    }

    /// "Send Again" on the conflict notification: the same content as a new clip within 120 s (CLIP-01 API 6).
    public func sendAgain() {
        guard let held = heldConflict, now().timeIntervalSince(held.heldAt) <= ClipboardConstants.staleAfter else {
            heldConflict = nil
            return
        }
        heldConflict = nil
        send(held.content, sensitive: held.sensitive, manual: true)
    }

    /// Debug builds only (`HLBENCH/1 clip_read_failed`): why a local copy was not sent, with the first item's
    /// pasteboard type identifiers when they explain it (CLIP-02 E3, CLIP-03 E1–E3). Never the content.
    private func readFailed(_ reason: String, manual: Bool, stage: String = "read", types: Bool = false) {
        var fields = [("reason", reason), ("stage", stage), ("source", manual ? "manual" : "auto")]
        if types { fields.append(("types", (access.firstItemTypes() ?? []).joined(separator: ",").ifEmptyDash())) }
        BenchLog.event("clip_read_failed", fields: fields)
    }

    /// First 8 hex digits of a `device_id` for `HLBENCH/1` lines.
    static func benchId(_ deviceId: String) -> String {
        String(deviceId.replacingOccurrences(of: "-", with: "").prefix(8))
    }
}

private extension String {
    func ifEmptyDash() -> String { isEmpty ? "-" : self }
}
