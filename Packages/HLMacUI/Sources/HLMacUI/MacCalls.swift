import Combine
import Foundation
import HLAppCore
import HLCallNotifications
import HLCalls
import HLLocalization
import HLProtocol
import HLSMS
import HLTransport

/// Calls on the Mac (CALL-01…04): the phone's call with its panel, ringtone and communication notification, the
/// commands, the call log with its missed-call notifications, and the Calls settings. The app model forwards the
/// connection events and owns the SMS side the quick replies use.
@MainActor
public final class MacCalls: ObservableObject {
    /// Settings mirrored for the views (SET-02 fields 10–12, CALL-02 field 8).
    @Published public internal(set) var callsEnabled: Bool
    @Published public internal(set) var callNotify: Bool
    @Published public internal(set) var callRingtone: Bool
    @Published public internal(set) var quickReplies: [String] = []
    /// HandLive may read the Focus status; without it "Ring on Mac" cannot ring (CALL-01 API 5 logic 3).
    @Published public internal(set) var focusAuthorized = false
    /// Unseen missed calls: the Calls item of the Messages window (CALL-04 field 7).
    @Published public internal(set) var missedBadge = 0
    /// The call list, over the encrypted database; `nil` without it.
    @Published public internal(set) var list: CallsModel?
    /// A call that rings now, for the menu bar menu (MenuBarMenu README: also after Ignore and during a Focus).
    @Published public internal(set) var ringingCall: ActiveCall?
    /// The latest missed calls, for the recent items of the menu bar menu (at most three).
    @Published public internal(set) var recentMissed: [MissedCall] = []

    public let controller: CallController
    public let panel = CallPanelModel()
    let presenter: any CallPanelPresenting
    let ringtone: any RingtonePlaying
    let focus: any FocusReading
    let notifier: any CallNotifying
    let settings: AppSettings
    var logEngine: CallLogEngine?
    var logStore: CallLogStore?
    var pruning: Task<Void, Never>?
    var subscription: AnyCancellable?
    var pairId: String?
    /// Calls answered from this Mac: their in-call panel shows even during a Focus.
    var answeredHere: Set<String> = []
    /// Calls that rang here already: the ringtone never starts twice for a call (a button, Ignore, 60 s end it).
    var ringDone: Set<String> = []
    /// The incoming notification posted for the call, and the last alert logged.
    var notifiedCallId: String?
    var lastAlert: (callId: String, alert: CallAlert)?

    /// Hooks the app model sets: sending an SMS, whether SMS can go out, the capability, the Calls list window.
    var sendSms: (_ number: String, _ subId: Int32?, _ text: String) async -> Void = { _, _, _ in }
    var smsCanSend: () -> Bool = { false }
    var capabilityChanged: () -> Void = {}
    var showCallList: () -> Void = {}

    public init(settings: AppSettings, presenter: (any CallPanelPresenting)? = nil,
                ringtone: any RingtonePlaying = SystemRingtone(), focus: any FocusReading = SystemFocusStatus(),
                notifier: any CallNotifying = UserNotificationCalls(), controller: CallController = CallController()) {
        self.settings = settings
        self.controller = controller
        self.ringtone = ringtone
        self.focus = focus
        self.notifier = notifier
        callsEnabled = settings.callsEnabled
        callNotify = settings.callNotify
        callRingtone = settings.callRingtone
        self.presenter = presenter ?? CallPanelController(model: panel)
        focusAuthorized = focus.isAuthorized
        controller.enabledHere = { [weak self] in self?.settings.callsEnabled ?? false }
        controller.onEvent = { [weak self] event in self?.handle(event) }
        panel.answer = { [weak self] in self?.command(.answer(.phone), from: .panel) }
        panel.decline = { [weak self] in self?.command(.reject(reply: nil), from: .panel) }
        panel.reply = { [weak self] text in self?.command(.reject(reply: text), from: .panel) }
        panel.ignore = { [weak self] in self?.ignore() }
        panel.end = { [weak self] in self?.command(.end, from: .panel) }
        subscription = controller.$call.dropFirst().sink { [weak self] call in
            // The controller publishes on the main actor; the panel must follow at once (≤ 300 ms, CALL-01).
            MainActor.assumeIsolated { self?.callChanged(call) }
        }
    }

    /// The call log over the encrypted database (CALL-04); without a database there is no call list.
    func start(database: SmsDatabase?) {
        loadQuickReplies()
        guard let database else { return }
        let store = CallLogStore(database: database)
        let engine = CallLogEngine(store: store)
        engine.enabledHere = { [weak self] in self?.settings.callsEnabled ?? false }
        engine.notifyEnabled = { [weak self] in self?.settings.callNotify ?? false }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        logStore = store
        logEngine = engine
        list = CallsModel(engine: engine, store: store)
        pruning?.cancel()
        pruning = Task { [weak engine] in
            while !Task.isCancelled {
                await engine?.pruneOld() // keep 90 days (CALL-04 Query)
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    /// The active pair: the controller, the call log and the list follow it.
    func setPair(_ record: PairedDeviceRecord?) {
        pairId = record?.pairId
        controller.setPair(record?.pairId, phoneDeviceId: record?.peerDeviceId, capability: record?.peerCapability)
        logEngine?.setPair(record?.pairId, capability: record?.peerCapability)
        list?.setPair(record?.pairId)
        panel.phoneName = record?.peerName ?? ""
        panel.callerIdHint = CallPermissions.missing(CallPermissions.callLog,
                                                     in: record?.peerCapability?.permissionsMissing ?? [])
    }

    /// The call part of the connection events (CONN-01 step 10, CONN-02).
    func linkEvent(_ event: LinkEvent) {
        switch event {
        case .connected(let session, let details):
            let peer = SessionCallPeer(session: session)
            controller.connected(peer: peer, capability: details.peerCapability)
            logEngine?.connected(peer: peer, capability: details.peerCapability)
            panel.callerIdHint = CallPermissions.missing(CallPermissions.callLog,
                                                         in: details.peerCapability.permissionsMissing ?? [])
        case .capabilityUpdated(let capability):
            controller.capabilityUpdated(capability)
            logEngine?.capabilityUpdated(capability)
            panel.callerIdHint = CallPermissions.missing(CallPermissions.callLog, in: capability.permissionsMissing ?? [])
        case .disconnected:
            controller.disconnected()
            logEngine?.disconnected()
        case .message(let envelope) where envelope.type == .callEvent:
            controller.receive(envelope)
            logEngine?.receive(envelope)
        default:
            break
        }
    }

    /// PAIR-03 step 7 and SET-02 A4: the pair's call log and its notifications go with it.
    func forget(pairId: String) {
        let store = logStore
        Task { try? await store?.deletePair(pairId) }
        notifier.removeAllCalls()
        recentMissed.removeAll()
    }

    /// "Delete All HandLive Data": nothing keeps using the database or showing a call.
    func stop() {
        pruning?.cancel()
        pruning = nil
        controller.setPair(nil)
        logEngine?.disconnected()
        logEngine = nil
        logStore = nil
        list?.close()
        list = nil
        ringtone.stop()
        presenter.hide()
        recentMissed.removeAll()
    }

    /// "Delete All HandLive Data" put the settings back to their defaults.
    func reloadSettings() {
        callsEnabled = settings.callsEnabled
        callNotify = settings.callNotify
        callRingtone = settings.callRingtone
        missedBadge = 0
        answeredHere.removeAll()
        ringDone.removeAll()
    }

    /// `call.quick_replies`: on first use the two default templates in the language of the moment, which then become
    /// user data (0.12.4, CALL-02 API 5 logic 3).
    func loadQuickReplies() {
        if settings.quickReplies == nil {
            settings.quickReplies = [L10n.Call.quickReplyCallBack, L10n.Call.quickReplyInMeeting]
        }
        quickReplies = settings.quickReplies ?? []
        panel.quickReplies = quickReplies
    }
}
