import AppKit
import Foundation
import HLAppCore
import HLCrypto
import HLDesignSystem
import HLProtocol
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
    let makeManager: @MainActor (CapabilityData) -> ConnectionManager

    /// `pairStoreURL` defaults to Application Support of the bundle identifier; tests pass a temporary file, a
    /// pasteboard and notifications of their own.
    public init(settings: AppSettings = AppSettings(), secrets: any SecretStore = KeychainSecretStore(),
                device: LocalDevice = .current(name: Host.current().localizedName ?? "Mac", platform: .macos),
                pairStoreURL: URL = PairedDeviceStore.defaultURL(
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.handlive.mac"),
                pasteboard: (any ClipboardAccess)? = nil, alerts: (any ClipboardAlerting)? = nil,
                makeManager: @escaping @MainActor (CapabilityData) -> ConnectionManager = {
                    ConnectionManager(localCapability: $0)
                }) {
        self.settings = settings
        self.secrets = secrets
        self.device = device
        self.pairStoreURL = pairStoreURL
        self.pasteboard = pasteboard ?? MacPasteboard()
        self.alerts = alerts ?? UserNotificationAlerts()
        self.makeManager = makeManager
        showInMenuBar = settings.showInMenuBar
        clipboardEnabled = settings.clipboardEnabled
        sendImages = settings.sendImages
        blockSensitive = settings.blockSensitive
        autoClearSeconds = settings.autoClearSeconds
        relayEnabled = settings.relayEnabled
    }

    /// "Send Clipboard to Phone" is available: connected, clipboard on here and on the phone (QC1).
    public var canSendClipboard: Bool {
        guard clipboardEnabled, case .connected = link.state else { return false }
        return pairedDevice?.peerCapability?.features.clipboard?.enabled ?? false
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
            startConnection()
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
        let manager = makeManager(device.capability(settings: settings))
        self.manager = manager
        let phone = activePhone()
        linkEvents = Task { [weak self] in
            await manager.start(phone: phone)
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
