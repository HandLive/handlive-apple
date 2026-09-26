import AppKit
import Foundation
import HLAppCore
import HLProtocol
import HLSMS
import HLSMSNotifications
import HLSMSUI
import HLTransport

extension AppModel {
    /// SMS on the Mac (SMS-01…05): the database keyed with `db_key` (0.6.1), the engine and the Messages screens. Without
    /// a database the Messages window has nothing to show and SMS stays off here (SMS-01 E7).
    func startMessages(identity: DeviceIdentityKeys) {
        guard let database = try? SmsDatabase(url: smsDatabaseURL, key: identity.databaseKey) else { return }
        let store = SmsStore(database: database)
        let engine = SmsEngine(store: store)
        engine.enabledHere = { [weak self] in self?.settings.smsEnabled ?? false }
        engine.notifyEnabled = { [weak self] in self?.settings.smsNotify ?? false }
        engine.onEvent = { [weak self] event in self?.handleSmsEvent(event) }
        alerts.onSmsResponse = { [weak self] response in self?.handleSmsNotification(response) }
        smsEngine = engine
        messages = MessagesModel(engine: engine, store: store)
        pairChangedForMessages()
        Task { try? await store.expireOutbox(now: HLUUID.currentTimeMs()) } // SMS-04: waiting > 24 h → failed
    }

    /// The engine and the screens follow the active pair.
    func pairChangedForMessages() {
        let record = pairedDevice
        smsEngine?.setPair(record?.pairId, phoneDeviceId: record?.peerDeviceId, capability: record?.peerCapability)
        messages?.setPair(record?.pairId)
        messages?.phoneName = record?.peerName ?? ""
    }

    /// SMS part of the connection events (CONN-01 step 10, CONN-02 step 10).
    func messagesLinkEvent(_ event: LinkEvent) {
        switch event {
        case .connected(let session, let details):
            smsEngine?.connected(peer: SessionSmsPeer(session: session), capability: details.peerCapability)
        case .capabilityUpdated(let capability): smsEngine?.capabilityUpdated(capability)
        case .disconnected: smsEngine?.disconnected()
        case .message(let envelope) where envelope.type == .sms: smsEngine?.receive(envelope)
        default: break
        }
    }

    func handleSmsEvent(_ event: SmsEvent) {
        messages?.apply(event)
        switch event {
        case .notify(let incoming): smsNotifier.post(incoming, showPreview: settings.smsPreview)
        case .removeNotifications(let pairId, let threadId, let upToTs):
            smsNotifier.remove(pairId: pairId, threadId: threadId, upToTs: upToTs)
        case .badge(let count): unreadThreads = count
        case .needsPhone: Task { await manager?.wakePhone(reason: .smsSend) } // CONN-04 step 5a
        case .syncStatus, .history, .removeGenericNotifications: break
        }
    }

    /// Reply (the Mac always runs, so as SMS-04 steps 2–12), Mark as Read (A2), or open the conversation.
    func handleSmsNotification(_ response: SmsNotificationResponse) {
        guard let engine = smsEngine else { return }
        switch response {
        case .reply(let info, let text):
            guard let address = info.address else { return }
            Task {
                _ = try? await engine.send(text: text, to: address, threadId: info.threadId, subId: info.subId)
                await engine.markAsRead(threadId: info.threadId)
            }
        case .markRead(let info): Task { await engine.markAsRead(threadId: info.threadId) }
        case .open(let info): showMessages(threadId: info.threadId)
        }
    }

    /// Opens the Messages window, on a conversation when given.
    public func showMessages(threadId: Int64? = nil) {
        if let threadId { messages?.selection = threadId }
        openMessagesWindow()
    }

    /// The Messages window opened or closed: the Dock icon and the app menu bar follow (SET-03 step 6).
    public func messagesWindowVisibilityChanged(_ open: Bool) {
        messagesWindowOpen = open
        applyActivationPolicy()
    }

    /// SET-02 fields 7–9.
    public func setSmsEnabled(_ enabled: Bool) {
        settings.smsEnabled = enabled
        smsEnabled = enabled
        scheduleCapabilityUpdate()
    }

    public func setSmsNotify(_ enabled: Bool) {
        settings.smsNotify = enabled
        smsNotify = enabled
    }

    public func setSmsPreview(_ enabled: Bool) {
        settings.smsPreview = enabled
        smsPreview = enabled
    }

    /// "Resync All SMS" after its confirmation (SMS-01 A1–A2).
    public func resyncAllSms() async {
        await smsEngine?.resyncAll()
    }

    /// PAIR-03 step 7 and SET-02 A4: the pair's synced SMS and its notifications go with it.
    func forgetMessages(pairId: String) {
        guard let messages else { return }
        let store = messages.store
        Task { try? await store.deletePair(pairId) }
        smsNotifier.removeAll()
        pairChangedForMessages()
    }
}
