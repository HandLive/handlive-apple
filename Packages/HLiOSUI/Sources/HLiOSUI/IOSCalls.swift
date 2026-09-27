import Combine
import Foundation
import HLAppCore
import HLCallNotifications
import HLCalls
import HLLocalization
import HLProtocol
import HLSMS
import HLTransport

/// Calls on iPhone and iPad (CALL-01 steps 8 and 12, CALL-02, CALL-04): the in-app banner with "Decline" while the app
/// is open, the removal of incoming-call notifications whose call moved on, the call log with its missed-call
/// notifications and the Calls tab badge, and the Calls settings. iPhone and iPad never answer (C7). The app model
/// forwards the connection events and owns the connection and SMS sides.
@MainActor
public final class IOSCalls: ObservableObject {
    /// Settings mirrored for the views (SET-02 fields 10–11); both travel in this device's capability.
    @Published public internal(set) var callsEnabled: Bool
    @Published public internal(set) var callNotify: Bool
    /// Unseen missed calls: the Calls tab badge (CALL-04 field 7).
    @Published public internal(set) var missedBadge = 0
    /// The call list over the encrypted database; `nil` without it.
    @Published public internal(set) var list: CallsModel?
    /// The call of the in-app banner (CALL-01 step 8): ringing or waiting, with call notifications on (E3).
    @Published public internal(set) var banner: ActiveCall?

    public let controller: CallController
    let settings: AppSettings
    let notifier: any IOSCallNotifying
    var logEngine: CallLogEngine?
    var logStore: CallLogStore?
    var pruning: Task<Void, Never>?
    var subscription: AnyCancellable?
    var pairId: String?
    /// The ringing call whose system notification may still show, and the last call whose ones were removed.
    var incomingCallId: String?
    var clearedCallId: String?
    /// The last call the banner came up for: VoiceOver and the bench line once per call.
    var announcedCallId: String?

    /// Hooks the app model sets: whether SMS can go out, the capability, reading the pair's pushes, VoiceOver.
    var smsCanSend: () -> Bool = { false }
    var capabilityChanged: () -> Void = {}
    var pushReader: () -> CallPushReader = { { _ in nil } }
    var announce: (String) -> Void = { _ in }

    public init(settings: AppSettings, notifier: any IOSCallNotifying, controller: CallController = CallController()) {
        self.settings = settings
        self.notifier = notifier
        self.controller = controller
        callsEnabled = settings.callsEnabled
        callNotify = settings.callNotify
        controller.enabledHere = { [weak self] in self?.settings.callsEnabled ?? false }
        controller.onEvent = { [weak self] event in self?.handle(event) }
        subscription = controller.$call.dropFirst().sink { [weak self] call in
            MainActor.assumeIsolated { self?.callChanged(call) }
        }
    }

    /// The call log over the encrypted database (CALL-04); without a database there is no call list.
    func start(database: SmsDatabase?) {
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
    }

    /// The call part of the connection events (CONN-01 step 10, CONN-02).
    func linkEvent(_ event: LinkEvent) {
        switch event {
        case .connected(let session, let details):
            let peer = SessionCallPeer(session: session)
            controller.connected(peer: peer, capability: details.peerCapability)
            logEngine?.connected(peer: peer, capability: details.peerCapability)
        case .capabilityUpdated(let capability):
            controller.capabilityUpdated(capability)
            logEngine?.capabilityUpdated(capability)
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

    /// The app went to the background, where pushes take over: no banner until the phone reports the call again.
    func enteredBackground() {
        controller.forgetCall()
    }

    /// The app came to the foreground: incoming-call notifications of calls that started over 60 s ago go (CALL-01
    /// API 6 logic 4).
    func becameActive(nowMs: Int64 = HLUUID.currentTimeMs()) {
        notifier.removeStaleIncoming(nowMs: nowMs, reader: pushReader())
    }

    /// A push shown while the app is open (CALL-01 API 6 logic 3): its ringing call becomes the banner's until the
    /// session brings the call itself.
    func pushed(_ state: CallStateData, envelopeTs: Int64) {
        controller.apply(state, envelopeTs: envelopeTs)
    }

    /// "Decline" on the banner (CALL-02 step 1).
    public func decline() {
        Task { await controller.perform(.reject(reply: nil), from: .banner) }
    }

    /// PAIR-03 step 7 and SET-02 A4: the pair's call log and its notifications go with it.
    func forget(pairId: String) {
        let store = logStore
        Task { try? await store?.deletePair(pairId) }
        notifier.removeAllCalls()
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
        banner = nil
    }

    /// "Delete All HandLive Data" put the settings back to their defaults.
    func reloadSettings() {
        callsEnabled = settings.callsEnabled
        callNotify = settings.callNotify
        missedBadge = 0
        incomingCallId = nil
        clearedCallId = nil
        announcedCallId = nil
    }
}
