import Foundation
import HLAppCore
import HLCrypto
import HLDesignSystem
import HLProtocol
import HLSMS
import HLSMSUI
import HLTransport

/// State and intents of the iPhone and iPad app: keys, the paired phone, the connection while the app is in the
/// foreground, the clipboard card, the Messages screens, settings and the push token. Views observe it; the app
/// delegate and the scene phase forward system events to it.
@MainActor
public final class IOSAppModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case launching
        /// SET-03 E1: the Keychain refused the keys; setup offers Try Again.
        case keysFailed
        case ready
    }

    /// The App Group shared with the Notification Service Extension: settings suite and keychain access group (0.2).
    public static let appGroup = "group.app.handlive"

    @Published public internal(set) var phase = Phase.launching
    @Published public internal(set) var link = LinkStatus(state: .idle(.notPaired))
    @Published public internal(set) var pairedDevice: PairedDeviceRecord?
    /// Settings mirrored for the views (SET-02 fields 1, 4, 6–9, 21).
    @Published public internal(set) var clipboardEnabled: Bool
    @Published public internal(set) var sendImages: Bool
    @Published public internal(set) var autoClearSeconds: Int
    @Published public internal(set) var relayEnabled: Bool
    @Published public internal(set) var smsEnabled: Bool
    @Published public internal(set) var smsNotify: Bool
    @Published public internal(set) var smsPreview: Bool
    /// Conversations shown as unread: the Messages tab badge and the app icon badge (SMS-05 field 4).
    @Published public internal(set) var unreadThreads = 0
    /// The Messages screens; `nil` until the keys load, or when the database cannot be opened (SMS-01 E7).
    @Published public internal(set) var messages: MessagesModel?
    /// The last clip received from the phone (PasteCard, CLIP-04 field 10).
    @Published public internal(set) var received: ReceivedClip?
    /// Content copied here and not sent yet: the suggestion banner (CLIP-04 field 3).
    @Published public internal(set) var unsentLocalContent = false
    /// The latest clipboard result in place (CLIP-04 fields 5, 7).
    @Published public internal(set) var clipboardNotice: ClipboardNotice?
    /// "Clipboard Not Updated on <name>" with "Send Again" (CLIP-04 fields 8–9).
    @Published public internal(set) var clipboardConflict: String?
    /// Result of a relay action in Settings (SET-02 field 30) or a relay account event (CONN-03 E3).
    @Published public internal(set) var relayNotice: String?
    @Published public internal(set) var notificationPermission = NotificationPermission.notDetermined
    /// The tab shown; a tap on an SMS notification switches to Messages.
    @Published public var selectedTab = IOSTab.clipboard

    let settings: AppSettings
    let secrets: any SecretStore
    public let device: LocalDevice
    var identity: DeviceIdentityKeys?
    var store: PairedDeviceStore?
    var manager: ConnectionManager?
    var relay: RelayServices?
    var linkEvents: Task<Void, Never>?
    var capabilityUpdate: Task<Void, Never>?
    var clipboard: ClipboardEngine?
    var smsEngine: SmsEngine?
    var outboxExpiry: Task<Void, Never>?
    var noticeReset: Task<Void, Never>?
    /// The APNs device token, kept until the relay accepted it (CONN-04 API 1).
    var pushToken: Data?
    var pushTokenSent = false
    let pasteboard: any ClipboardAccess
    let notifications: any IOSNotifying
    let pairStoreURL: URL
    let smsDatabaseURL: URL
    /// `apns_sandbox` for development builds, `apns` for TestFlight and the App Store (CONN-04 API 1).
    let pushProvider: RelayPushTokenRequest.Provider
    /// The APNs topic, the bundle identifier of the app (`RELAY_APNS_TOPIC`).
    let pushTopic: String
    let makeRelay: @MainActor (RelayIdentity) -> RelayServices?
    let makeManager: @MainActor (CapabilityData, RelayServices?) -> ConnectionManager
    /// The app is in the foreground: only then a session to the phone stays open (CONN-02 E3, CLIP-04 E1).
    var inForeground = true
    /// How long a quick reply waits for the phone before "Not sent yet" (SMS-04 API 5: about 20 s).
    var quickReplyDeadline: Duration = .seconds(20)
    /// "Delete All HandLive Data" finished: the app starts over at setup (SET-02 A6).
    public var didEraseAllData: () -> Void = {}

    public init(settings: AppSettings, secrets: any SecretStore, device: LocalDevice, pairStoreURL: URL,
                smsDatabaseURL: URL, pasteboard: any ClipboardAccess, notifications: any IOSNotifying,
                pushProvider: RelayPushTokenRequest.Provider, pushTopic: String,
                makeRelay: @escaping @MainActor (RelayIdentity) -> RelayServices?,
                makeManager: @escaping @MainActor (CapabilityData, RelayServices?) -> ConnectionManager = {
                    ConnectionManager(localCapability: $0, relay: $1)
                }) {
        self.settings = settings
        self.secrets = secrets
        self.device = device
        self.pairStoreURL = pairStoreURL
        self.smsDatabaseURL = smsDatabaseURL
        self.pasteboard = pasteboard
        self.notifications = notifications
        self.pushProvider = pushProvider
        self.pushTopic = pushTopic
        self.makeRelay = makeRelay
        self.makeManager = makeManager
        clipboardEnabled = settings.clipboardEnabled
        sendImages = settings.sendImages
        autoClearSeconds = settings.autoClearSeconds
        relayEnabled = settings.relayEnabled
        smsEnabled = settings.smsEnabled
        smsNotify = settings.smsNotify
        smsPreview = settings.smsPreview
    }

    /// `true` once `setup.completed_at` is set (SET-03 step 1).
    public var setupCompleted: Bool { settings.setupCompletedAt != nil }

    /// This device's `device_id`, once the keys are loaded.
    public var deviceId: String? { identity?.deviceId }

    /// Status for `StatusIndicator`.
    public var connectionStatus: HLConnectionStatus {
        HLConnectionStatus(link: link, lastSeen: pairedDevice?.lastSeenAt)
    }

    /// Connected to the phone: the Paste button works (CLIP-04 E5).
    public var connected: Bool {
        if case .connected = link.status { return true }
        return false
    }

    /// SET-03 step 2: load or create the keys, open the pair store, start the clipboard, SMS and the connection.
    public func launch() {
        do {
            let keys = try DeviceIdentityKeys.loadOrCreate(secrets: secrets, settings: settings)
            identity = keys
            BenchLog.configure(deviceId: keys.deviceId, role: .ios)
            let store = PairedDeviceStore(fileURL: pairStoreURL, databaseKey: keys.databaseKey)
            self.store = store
            pairedDevice = try? store.active()
            phase = .ready
            startClipboard(identity: keys)
            startMessages(identity: keys)
            startConnection(identity: keys)
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

    private func startConnection(identity: DeviceIdentityKeys) {
        relay = makeRelay(RelayIdentity(deviceId: identity.deviceId, signingSeed: identity.signingSeed,
                                        signingPublicKey: identity.signingPublicKey, platform: device.platform,
                                        appVersion: device.appVersion))
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
        guard settings.setupCompletedAt == nil else { return }
        objectWillChange.send()
        settings.setupCompletedAt = HLUUID.currentTimeMs()
    }

    /// "Reconnect Now".
    public func reconnectNow() {
        Task { await manager?.reconnectNow() }
    }

    // MARK: - Scene phase (CONN-02 E3, CLIP-04 step 2)

    /// The scene became active: reconnect, look at the clipboard's `changeCount`, re-read the notification state.
    public func sceneBecameActive() {
        inForeground = true
        clipboard?.localChangeSeen()
        messages?.setActive(true)
        Task {
            await manager?.systemDidWake()
            notificationPermission = await notifications.permission()
        }
    }

    /// The scene went to the background: `session/bye {shutdown}` and no session until it comes back; SMS and calls
    /// then arrive through push (CONN-04).
    public func sceneEnteredBackground() {
        inForeground = false
        messages?.setActive(false)
        Task { await manager?.systemWillSleep() }
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
