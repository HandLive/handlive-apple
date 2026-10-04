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
            BenchLog.event("clip_read_failed", ["reason": "paste_access", "stage": "poll", "source": "auto"])
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
}
