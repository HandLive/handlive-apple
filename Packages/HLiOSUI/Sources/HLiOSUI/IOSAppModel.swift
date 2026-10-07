import Foundation
import HLAppCore
import HLCalls
import HLCrypto
import HLDesignSystem
import HLProtocol
import HLSMS
import HLSMSUI
import HLTransport

/// State and intents of the iPhone and iPad app: keys, the paired phone, the connection while the app is in the
/// foreground, the clipboard card, the Messages screens, calls, settings and the push token. Views observe it; the app
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
    public static let appGroup = "group.app.hxd.handlive"

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
    /// Time Sensitive notifications for the app (SET-03 field 8): off, a Focus may silence incoming calls.
    @Published public internal(set) var timeSensitive = TimeSensitiveSetting.enabled
    /// The tab shown; a tap on an SMS notification switches to Messages, on a missed call to Calls.
    @Published public var selectedTab = IOSTab.clipboard
    /// Calls: the banner, the call log and the Calls tab (CALL-01…04).
    public let calls: IOSCalls

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
    /// The app is in the foreground: the session stays open; in the background only while something holds it (CONN-02
    /// E3, CLIP-04 E1).
    var inForeground = true
    /// How long a quick reply waits for the phone before "Not sent yet" (SMS-04 API 5: about 20 s).
    var quickReplyDeadline: Duration = .seconds(20)
    /// `IOS_BACKGROUND_GRACE`: how long the session stays after the app leaves the foreground, at most the system's time
    /// left less 5 s (CONN-02 E3).
    var backgroundGrace: Duration = .seconds(25)
    /// The session in the background: its holders, the grace, the close/reopen queue (`IOSAppModel+Background.swift`).
    var hold = ConnectionHold()
    let backgroundTasks: any BackgroundTaskProviding
    /// `CALL_REJECT_BG_TIMEOUT`: "Decline" from a notification, the background connection included (CALL-02 E8).
    var callRejectDeadline: Duration = .seconds(15)
    /// A "Decline" from a notification waits for the phone: a relay without the phone wakes it (CALL-02 API 6).
    var callActionPending = false
    /// "Delete All HandLive Data" finished: the app starts over at setup (SET-02 A6).
    public var didEraseAllData: () -> Void = {}

    public init(settings: AppSettings, secrets: any SecretStore, device: LocalDevice, pairStoreURL: URL,
                smsDatabaseURL: URL, pasteboard: any ClipboardAccess, notifications: any IOSNotifying,
                callNotifications: any IOSCallNotifying, pushProvider: RelayPushTokenRequest.Provider, pushTopic: String,
                makeRelay: @escaping @MainActor (RelayIdentity) -> RelayServices?,
                backgroundTasks: any BackgroundTaskProviding = NoBackgroundTasks(),
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
        self.backgroundTasks = backgroundTasks
        calls = IOSCalls(settings: settings, notifier: callNotifications)
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

    /// SET-03 step 2: load or create the keys, open the pair store (its second slot when the file is sealed with another
    /// `db_key`, API 1 logic 5), start the clipboard, SMS and the connection.
    public func launch() {
        do {
            let keys = try DeviceIdentityKeys.loadOrCreate(secrets: secrets, settings: settings)
            identity = keys
            BenchLog.configure(deviceId: keys.deviceId, role: .ios)
            let store = PairedDeviceStore.open(fileURL: pairStoreURL, databaseKey: keys.databaseKey)
            self.store = store
            pairedDevice = try? store.active()
            phase = .ready
            startClipboard(identity: keys)
            startMessages(identity: keys)
            startCalls()
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

    /// SET-03 step 13: first run done; the device registers with the relay in the background (a failure is retried by
    /// the next relay use, E7) and the phone can be paired now.
    public func completeSetup() {
        guard settings.setupCompletedAt == nil else { return }
        objectWillChange.send()
        settings.setupCompletedAt = HLUUID.currentTimeMs()
        if relayEnabled, let api = relay?.api { Task { try? await api.registerDevice() } }
    }

    /// "Reconnect Now".
    public func reconnectNow() {
        Task { await manager?.reconnectNow() }
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
