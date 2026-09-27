import Foundation
import HLAppCore
import HLProtocol
import HLSMS
import HLSMSNotifications
import HLSMSUI
import HLTransport

/// The tabs of the app (02-ios-ipados.md, Tab bar); Calls comes with Phase 3.
public enum IOSTab: Hashable, Sendable {
    case clipboard, messages, settings
}

extension IOSAppModel {
    /// SMS on this device (SMS-01…05): the database keyed with `db_key` in the app's own container, the engine and the
    /// Messages screens. Without a database SMS stays off here (SMS-01 E7).
    func startMessages(identity: DeviceIdentityKeys) {
        guard let database = try? SmsDatabase(url: smsDatabaseURL, key: identity.databaseKey) else { return }
        let store = SmsStore(database: database)
        let engine = SmsEngine(store: store)
        engine.enabledHere = { [weak self] in self?.settings.smsEnabled ?? false }
        engine.notifyEnabled = { false } // the app open shows the message itself; closed, push does (CONN-04)
        engine.onEvent = { [weak self] event in self?.handleSmsEvent(event) }
        smsEngine = engine
        messages = MessagesModel(engine: engine, store: store)
        pairChangedForMessages()
        outboxExpiry?.cancel()
        outboxExpiry = Task {
            while !Task.isCancelled {
                try? await store.expireOutbox(now: HLUUID.currentTimeMs()) // SMS-04 E1: waiting > 24 h → Not sent
                try? await Task.sleep(for: .seconds(3600))
            }
        }
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
        case .removeNotifications(let pairId, let threadId, let upToTs):
            notifications.remove(pairId: pairId, threadId: threadId, upToTs: upToTs)
        case .removeGenericNotifications: notifications.removeGeneric()
        case .badge(let count):
            unreadThreads = count
            notifications.setBadge(count)
        case .needsPhone: Task { await manager?.wakePhone(reason: .smsSend) } // CONN-04 step 5a
        case .notify, .syncStatus, .history: break
        }
    }

    /// SMS-04 API 5 on iOS: the system woke the app for "Reply". Connect (CONN-01 or CONN-03), send, and wait about
    /// 20 s for the phone to accept; otherwise the message waits, "Not sent yet" is posted and the next opening sends
    /// it. Mark as Read and a tap on the notification are handled here too.
    public func handleSmsNotification(_ response: SmsNotificationResponse) async {
        switch response {
        case .reply(let info, let text):
            _ = await quickReply(info, text: text)
        case .markRead(let info):
            await smsEngine?.markAsRead(threadId: info.threadId)
        case .open(let info):
            selectedTab = .messages
            messages?.selection = info.threadId
        }
    }

    func quickReply(_ info: SmsNotificationInfo, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine = smsEngine, let address = info.address, !trimmed.isEmpty else { return false } // logic 4
        let wasInBackground = !inForeground
        if wasInBackground { await manager?.systemDidWake() }
        let accepted = await engine.quickReply(text: trimmed, to: address, threadId: info.threadId, subId: info.subId,
                                               deadline: quickReplyDeadline)
        if !accepted { notifications.postNotSentYet(pairId: info.pairId, threadId: info.threadId) }
        if wasInBackground, !inForeground { await manager?.systemWillSleep() }
        return accepted
    }

    /// SET-02 fields 7–9: `sms.notify` is in this device's capability (the phone pushes only when it is on).
    public func setSmsEnabled(_ enabled: Bool) {
        settings.smsEnabled = enabled
        smsEnabled = enabled
        scheduleCapabilityUpdate()
    }

    public func setSmsNotify(_ enabled: Bool) {
        settings.smsNotify = enabled
        smsNotify = enabled
        scheduleCapabilityUpdate()
    }

    public func setSmsPreview(_ enabled: Bool) {
        settings.smsPreview = enabled // the extension reads it from the App Group suite
        smsPreview = enabled
    }

    /// "Resync All SMS" after its confirmation (SMS-01 A1–A2).
    public func resyncAllSms() async {
        await smsEngine?.resyncAll()
    }

    /// "Resync All SMS" needs a session to the phone and SMS active (SET-02 field 25).
    public var canResyncSms: Bool {
        connected && smsEngine?.isActive == true
    }

    /// PAIR-03 step 7 and SET-02 A4: the pair's synced SMS and its notifications go with it.
    func forgetMessages(pairId: String) {
        guard let messages else { return }
        let store = messages.store
        Task { try? await store.deletePair(pairId) }
        notifications.removeAllSms()
        pairChangedForMessages()
    }
}
