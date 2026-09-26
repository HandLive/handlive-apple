import AppKit
import Foundation
import HLAppCore
import HLCrypto
import HLDesignSystem
import HLProtocol
import HLSMS
import HLSMSUI
import HLTransport

/// State and intents of the Mac app: keys, the paired phone, the connection, settings and first-run progress.
/// Views observe it; the app delegate forwards system events (sleep, wake, reopen) to it.
@MainActor
public final class AppModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case launching
        /// SET-03 E1: the Keychain refused the keys; setup offers Try Again.
        case keysFailed
        case ready
    }

    @Published public private(set) var phase = Phase.launching
    @Published public internal(set) var link = LinkStatus(state: .idle(.notPaired))
    @Published public internal(set) var pairedDevice: PairedDeviceRecord?
    @Published public internal(set) var loginItemStatus = LoginItem.status
    @Published public internal(set) var pasteAccess = PasteAccess.current
    /// Settings mirrored for the views (SET-02 fields 1, 4–6, 21, 31); setters live in `AppModel+Settings`.
    @Published public internal(set) var showInMenuBar: Bool
    @Published public internal(set) var clipboardEnabled: Bool
    @Published public internal(set) var sendImages: Bool
    @Published public internal(set) var blockSensitive: Bool
    @Published public internal(set) var autoClearSeconds: Int
    @Published public internal(set) var relayEnabled: Bool
    /// Short message in the menu bar menu (clipboard errors, CLIP-01 E5 / CLIP-02 E8).
    @Published public internal(set) var menuStatusLine: String?
    /// Symbol shown for about a second on the menu bar icon after a manual send (Feedback, M1.4).
    @Published public internal(set) var menuBarFeedback: String?
    /// Image transfers over 1 MiB in progress, one per direction (CLIP-03 field 2).
    @Published public internal(set) var clipboardProgress: [ClipboardProgress.Direction: ClipboardProgress] = [:]
    /// SMS settings mirrored for the views (SET-02 fields 7–9).
    @Published public internal(set) var smsEnabled: Bool
    @Published public internal(set) var smsNotify: Bool
    @Published public internal(set) var smsPreview: Bool
    /// Conversations shown as unread: the badge right after the menu bar icon (SMS-02 field 6).
    @Published public internal(set) var unreadThreads = 0
    /// The Messages screens; `nil` until the keys load, or when the database cannot be opened (SMS-01 E7).
    @Published public internal(set) var messages: MessagesModel?
    /// Result of a relay action in Settings (SET-02 field 30) or a relay problem (CONN-03 field 4).
    @Published public internal(set) var relayNotice: String?

    let settings: AppSettings
    let secrets: any SecretStore
    public let device: LocalDevice
    var identity: DeviceIdentityKeys?
    var store: PairedDeviceStore?
    var manager: ConnectionManager?
    var capabilityUpdate: Task<Void, Never>?
    var linkEvents: Task<Void, Never>?
    var clipboard: ClipboardEngine?
    var statusLineReset: Task<Void, Never>?
    let pasteboard: any ClipboardAccess
    let alerts: any ClipboardAlerting
    let pairStoreURL: URL
    let smsDatabaseURL: URL
    let makeManager: @MainActor (CapabilityData, RelayServices?) -> ConnectionManager
    /// The relay services of this device (CONN-03): from `{RELAY_HOST}` of the build; `nil` without one: LAN only.
    let makeRelay: @MainActor (RelayIdentity) -> RelayServices?
    var relay: RelayServices?
    var smsEngine: SmsEngine?
    /// Hourly check of the outbox: a message waiting more than 24 h becomes "Not sent" (SMS-04 E1).
    var outboxExpiry: Task<Void, Never>?
    let smsNotifier: any SmsNotifying
    /// The Messages window is open: the app shows its Dock icon and menu bar (SET-03 step 6).
    var messagesWindowOpen = false
    /// Opens the Messages window (the app coordinator's window presenter).
    public var openMessagesWindow: () -> Void = {}
    /// "Delete All HandLive Data" finished: the windows start over at the welcome window (SET-02 A6).
    public var didEraseAllData: () -> Void = {}

    /// `pairStoreURL` defaults to Application Support of the bundle identifier; tests pass a temporary file, a
    /// pasteboard and notifications of their own.
    public init(settings: AppSettings = AppSettings(), secrets: any SecretStore = KeychainSecretStore(),
                device: LocalDevice = .current(name: Host.current().localizedName ?? "Mac", platform: .macos),
                pairStoreURL: URL = PairedDeviceStore.defaultURL(
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.handlive.mac"),
                smsDatabaseURL: URL = SmsDatabase.defaultURL(
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.handlive.mac"),
                pasteboard: (any ClipboardAccess)? = nil, alerts: (any ClipboardAlerting)? = nil,
                smsNotifier: (any SmsNotifying)? = nil,
                makeRelay: @escaping @MainActor (RelayIdentity) -> RelayServices? = { identity in
                    RelayConfiguration.fromBundle().map { RelayServices.live(configuration: $0, identity: identity) }
                },
                makeManager: @escaping @MainActor (CapabilityData, RelayServices?) -> ConnectionManager = {
                    ConnectionManager(localCapability: $0, relay: $1)
                }) {
        self.settings = settings
        self.secrets = secrets
        self.device = device
        self.pairStoreURL = pairStoreURL
        self.smsDatabaseURL = smsDatabaseURL
        self.pasteboard = pasteboard ?? MacPasteboard()
        self.alerts = alerts ?? UserNotificationAlerts()
        self.smsNotifier = smsNotifier ?? UserNotificationSms()
        self.makeRelay = makeRelay
        self.makeManager = makeManager
        showInMenuBar = settings.showInMenuBar
        clipboardEnabled = settings.clipboardEnabled
        sendImages = settings.sendImages
        blockSensitive = settings.blockSensitive
        autoClearSeconds = settings.autoClearSeconds
        relayEnabled = settings.relayEnabled
        smsEnabled = settings.smsEnabled
        smsNotify = settings.smsNotify
        smsPreview = settings.smsPreview
    }

    /// "Send Clipboard to Phone" is available with a paired phone and clipboard on here and, as far as known, on the
    /// phone (QC1). While disconnected it keeps the clip and says it will send on reconnection (CLIP-02 E6).
    public var canSendClipboard: Bool {
        guard clipboardEnabled, let device = pairedDevice else { return false }
        return device.peerCapability?.features.clipboard?.enabled ?? true
    }

    /// `true` once `setup.completed_at` is set (SET-03 step 1).
    public var setupCompleted: Bool { settings.setupCompletedAt != nil }

    /// This device's `device_id`, once the keys are loaded.
    public var deviceId: String? { identity?.deviceId }

    /// Status for `StatusIndicator` and the menu bar icon.
    public var connectionStatus: HLConnectionStatus {
        HLConnectionStatus(link: link, lastSeen: pairedDevice?.lastSeenAt)
    }

    /// SET-03 step 2: load or create the keys, open the pair store, start the connection manager.
    public func launch() {
        do {
            let keys = try DeviceIdentityKeys.loadOrCreate(secrets: secrets, settings: settings)
            identity = keys
            BenchLog.configure(deviceId: keys.deviceId, role: .macos)
            let store = PairedDeviceStore(fileURL: pairStoreURL, databaseKey: keys.databaseKey)
            self.store = store
            pairedDevice = try? store.active()
            phase = .ready
            startClipboard(identity: keys)
            startMessages(identity: keys)
            startConnection()
            Task { await revokeTombstones() } // PAIR-03 E3: revocations that waited for a network
        } catch IdentityError.keysMissing {
            // The Keychain lost the keys after setup started: start over as a fresh install.
            settings.setupStartedAt = nil
            settings.setupCompletedAt = nil
            launch()
        } catch {
            phase = .keysFailed
        }
    }

    /// "Try Again" after SET-03 E1.
    public func retryKeys() {
        phase = .launching
        launch()
    }

    private func startConnection() {
        if let identity {
            relay = makeRelay(RelayIdentity(
                deviceId: identity.deviceId, signingSeed: identity.signingSeed,
                signingPublicKey: identity.signingPublicKey, platform: device.platform, appVersion: device.appVersion))
        }
        let manager = makeManager(device.capability(settings: settings), relay)
        self.manager = manager
        let phone = activePhone()
        let relayOn = settings.relayEnabled
        linkEvents = Task { [weak self] in
            await manager.start(phone: phone, relayEnabled: relayOn)
            for await event in manager.events {
                await self?.handle(event)
            }
        }
    }

    /// The active pair with its `PRK`, as the connection manager needs it.
    func activePhone() -> PairedPhone? {
        guard let identity, let record = pairedDevice,
              let prk = try? secrets.load(account: SecretAccount.pairKey(pairId: record.pairId))
        else { return nil }
        return record.pairedPhone(clientDeviceId: identity.deviceId, prk: prk)
    }

    /// SET-03 step 13: first run done; the phone can be paired now.
    public func completeSetup() {
        if settings.setupCompletedAt == nil { settings.setupCompletedAt = HLUUID.currentTimeMs() }
    }

    /// "Reconnect Now".
    public func reconnectNow() {
        Task { await manager?.reconnectNow() }
    }

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
    }

    /// Quit: `session/bye {shutdown}` first (CONN-02 step 8).
    public func prepareToQuit() async {
        await manager?.stop()
    }
}
