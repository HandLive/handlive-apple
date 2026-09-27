import Foundation
import HLCrypto
import HLProtocol
import HLTransport

/// Where the engine runs: the Mac polls and reads the clipboard itself (C10); the iPhone and iPad never read it and
/// send only what the user pastes with the system Paste button (CLIP-04).
public enum ClipboardPlatform: Sendable {
    case mac, ios
}

/// Clipboard sync with the phone (CLIP-01…05): on the Mac polls `changeCount`, reads and sends local clips; everywhere
/// writes the phone's clips, keeps the latest unacknowledged clip for replay, resolves conflicts and clears received
/// content. Content lives only in memory and in temporary transfer files; it is never logged (QC2).
@MainActor
public final class ClipboardEngine {
    /// The phone while a session is up.
    struct Phone {
        let peer: any ClipboardPeer
        let deviceId: String
        let name: String
        var feature: ClipboardFeature?
        /// `FEATURE_DISABLED` from the phone: inactive until its next `capability/update` (CLIP-01 E10).
        var suspended = false
    }

    public var onNotice: (ClipboardNotice) -> Void = { _ in }
    public var onAlert: (ClipboardAlert) -> Void = { _ in }
    /// Progress of the transfer in one direction; `nil` when it ended.
    public var onProgress: (ClipboardProgress.Direction, ClipboardProgress?) -> Void = { _, _ in }
    /// iPhone/iPad: locally copied content not sent yet appeared or went away (the suggestion banner, CLIP-04 field 3).
    public var onUnsentLocalContent: (Bool) -> Void = { _ in }
    /// A clip from the phone was written to the clipboard.
    public var onReceived: (ReceivedClip) -> Void = { _ in }
    /// The latest clip written from the phone (PasteCard on iPhone and iPad).
    public internal(set) var lastReceived: ReceivedClip?

    let access: any ClipboardAccess
    let platform: ClipboardPlatform
    let settings: AppSettings
    let deviceId: String
    let deviceName: String
    let now: () -> Date
    let temporaryDirectory: URL
    /// macOS lets the app read the clipboard without asking (C10); `false` stops automatic reading.
    let readingAllowed: () -> Bool
    var pollInterval = ClipboardConstants.pollInterval
    var transferIdleTimeout = ClipboardConstants.transferIdleTimeout

    var phone: Phone?
    var lastSeenChangeCount: Int
    var ownWrite: OwnWrite?
    /// SHA-256 and time of the clip last written from the phone (QC4).
    var received: (sha256: Data, at: Date)?
    var latestLocal: OutgoingClip?
    var ledger = ClipLedger()
    var incoming: IncomingTransfer?
    var sending: SendingState?
    var heldSensitive: HeldClip?
    var heldConflict: HeldClip?
    /// A local copy seen by `poll` whose clip is still being read (an image being normalized): counts for QC8.
    var detectedLocalChange: Date?
    var pollTask: Task<Void, Never>?
    var autoClearTask: Task<Void, Never>?
    var pasteGuideShown = false
    /// iPhone/iPad: when the phone's session started, for the 5 s rule of CLIP-04 E2.
    var sessionStartedAt: Date?
    /// iPhone/iPad: content copied here and not sent yet (CLIP-04 step 2, E2).
    public internal(set) var unsentLocalContent = false

    public init(access: any ClipboardAccess, settings: AppSettings, deviceId: String, deviceName: String,
                platform: ClipboardPlatform = .mac, readingAllowed: @escaping () -> Bool,
                now: @escaping () -> Date = Date.init,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HandLive/clip", isDirectory: true)) {
        self.access = access
        self.platform = platform
        self.settings = settings
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.readingAllowed = readingAllowed
        self.now = now
        self.temporaryDirectory = temporaryDirectory
        lastSeenChangeCount = platform == .ios ? settings.seenChangeCount : access.changeCount
        rearmAutoClearAfterRestart()
    }

    // MARK: - Polling (CLIP-02 API 1)

    /// Runs while a phone is paired and `feature.clipboard` is on, also while disconnected (QC7); stops for sleep.
    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
                self?.poll()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public var isPolling: Bool { pollTask != nil }

    /// One poll: nothing is read while `changeCount` is unchanged or HandLive wrote the change (E1). The iPhone and
    /// iPad never read: a new `changeCount` only marks unsent local content.
    public func poll() {
        guard platform == .mac else { return localChangeSeen() }
        let count = access.changeCount
        guard count != lastSeenChangeCount else { return }
        lastSeenChangeCount = count
        guard count != ownWrite?.changeCount, settings.clipboardEnabled else { return }
        BenchLog.event("copy_detected")
        guard readingAllowed() else {
            if !pasteGuideShown {
                pasteGuideShown = true
                onNotice(.pasteAccessNeeded)
            }
            return
        }
        detectedLocalChange = now()
        capture(manual: false)
    }

    /// "Send Clipboard to Phone" (CLIP-02 field 4): reads at once, even when macOS asks first (`.ask`).
    public func sendClipboardNow() {
        lastSeenChangeCount = access.changeCount
        capture(manual: true)
    }

    /// Mac sleep and wake (CLIP-02 logic 4, CLIP-05 E6).
    public func systemWillSleep() {
        stopPolling()
    }

    public func systemDidWake(pollingWanted: Bool) {
        checkAutoClear()
        if pollingWanted {
            poll()
            startPolling()
        }
    }

    // MARK: - Local clips (CLIP-02 steps 3–8, CLIP-03 steps 2–5)

    private func capture(manual: Bool) {
        switch LocalClipReader.read(access) {
        case .ownWrite:
            // What is on the clipboard came from the phone: never sent back (QC4).
            detectedLocalChange = nil
            if manual, let phone { onNotice(.skippedJustReceived(deviceName: phone.name)) }
        case .unsupported:
            detectedLocalChange = nil
            if manual { onNotice(.emptyOrNotText) }
        case .text(let text, let sensitiveType):
            captureText(text, sensitiveType: sensitiveType, manual: manual)
        case .image(let data, let type, let sensitiveType):
            guard settings.sendImages else {
                detectedLocalChange = nil
                if manual { onNotice(.emptyOrNotText) }
                return
            }
            Task {
                let image = await Task.detached(priority: .userInitiated) {
                    ImageNormalizer.normalize(data, typeIdentifier: type)
                }.value
                captureImage(image, sensitiveType: sensitiveType, manual: manual)
            }
        }
    }

    private func captureText(_ text: String, sensitiveType: Bool, manual: Bool) {
        detectedLocalChange = nil
        let content = ClipContent.text(text)
        if let received, received.sha256 == content.sha256,
           now().timeIntervalSince(received.at) < ClipboardConstants.loopWindow {
            if manual, let phone { onNotice(.skippedJustReceived(deviceName: phone.name)) }
            return
        }
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
            if manual { onNotice(.imageUnreadable) }
            return
        }
        guard image.data.count <= ClipboardConstants.maxImageBytes else {
            onNotice(.imageTooLarge)
            return
        }
        let content = ClipContent.image(image)
        if let received, received.sha256 == content.sha256,
           now().timeIntervalSince(received.at) < ClipboardConstants.loopWindow { return }
        if settings.blockSensitive, sensitiveType {
            hold(content, as: .sensitiveBlocked)
            return
        }
        send(content, sensitive: false, manual: manual)
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

    /// First 8 hex digits of a `device_id` for `HLBENCH/1` lines.
    static func benchId(_ deviceId: String) -> String {
        String(deviceId.replacingOccurrences(of: "-", with: "").prefix(8))
    }
}
