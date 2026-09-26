import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLSMS
import HLSMSNotifications
import HLTransport
import Testing
@testable import HLMacUI

@Suite("Mac app model: Messages")
@MainActor
struct AppModelMessagesTests {
    static let address = "+84900000123"

    @Test("sms/new is stored, notified with the preview setting and counted on the menu bar icon (SMS-02, SMS-05)")
    func incomingMessage() async throws {
        let sms = StubSmsNotifier()
        let model = makeModel(sms: sms)
        model.launch()
        try model.completePairing(PairingControllerTests.result())
        let messages = try #require(model.messages)
        model.setSmsPreview(false)
        await model.handle(.message(Self.new(1, ts: 1_000)))
        #expect(await eventually { sms.posted.count == 1 && model.unreadThreads == 1 })
        #expect(sms.previews == [false] && sms.posted.first?.message.messageKey == "sms:1")
        #expect(await eventually { messages.threads.map(\.threadId) == [7] })
        // The same message again (a resent sms/new) is not notified twice.
        await model.handle(.message(Self.new(1, ts: 1_000)))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sms.posted.count == 1)
        // Mark as Read from the notification: read here only, its notifications go, the badge follows (SMS-05 A2).
        let info = try #require(SmsNotificationInfo(SmsNotificationKeys.userInfo(pairId: messages.pairId ?? "",
                                                                                 message: Self.message(1, ts: 1_000))))
        model.handleSmsNotification(.markRead(info))
        #expect(await eventually { model.unreadThreads == 0 })
        #expect(sms.removed.contains { $0.threadId == 7 && $0.upToTs == nil })
    }

    @Test("Notifications off (SET-02 field 8): the message is stored and counted but not notified")
    func notificationsOff() async throws {
        let sms = StubSmsNotifier()
        let model = makeModel(sms: sms)
        model.launch()
        try model.completePairing(PairingControllerTests.result())
        model.setSmsNotify(false)
        #expect(!model.smsNotify && !model.settings.smsNotify)
        await model.handle(.message(Self.new(2, ts: 2_000)))
        #expect(await eventually { model.unreadThreads == 1 })
        #expect(sms.posted.isEmpty)
    }

    @Test("Reply from a notification waits in the outbox while the phone is away and wakes it (SMS-04 API 5, CONN-04)")
    func replyOffline() async throws {
        let model = makeModel()
        model.launch()
        try model.completePairing(PairingControllerTests.result())
        let messages = try #require(model.messages)
        let pairId = try #require(messages.pairId)
        await model.handle(.message(Self.new(3, ts: 3_000)))
        #expect(await eventually { model.unreadThreads == 1 })
        let info = try #require(SmsNotificationInfo(SmsNotificationKeys.userInfo(pairId: pairId,
                                                                                 message: Self.message(3, ts: 3_000))))
        model.handleSmsNotification(.reply(info, text: "OK, 3h nhé"))
        var pending: [SmsOutboxEntry] = []
        for _ in 0..<100 where pending.isEmpty {
            pending = (try? await messages.store.pending(pairId: pairId)) ?? []
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(pending.map(\.body) == ["OK, 3h nhé"] && pending.first?.addresses == [Self.address])
        #expect(await eventually { model.unreadThreads == 0 })
    }

    @Test("Forgetting the phone deletes its messages and every SMS notification (PAIR-03 step 7)")
    func forgetPairDeletesMessages() async throws {
        let sms = StubSmsNotifier()
        let model = makeModel(sms: sms)
        model.launch()
        try model.completePairing(PairingControllerTests.result())
        let messages = try #require(model.messages)
        let pairId = try #require(messages.pairId)
        await model.handle(.message(Self.new(4, ts: 4_000)))
        #expect(await eventually { messages.threads.count == 1 })
        model.forgetPair()
        #expect(sms.removedAll == 1 && messages.pairId == nil)
        #expect(await eventually { messages.threads.isEmpty })
        var left = 1
        for _ in 0..<100 where left > 0 {
            left = (try? await messages.store.unreadThreadCount(pairId: pairId)) ?? 1
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(left == 0)
    }

    @Test("SMS on this Mac (SET-02 field 7) persists and the Messages window brings the Dock icon")
    func settingsAndWindow() {
        let model = makeModel()
        model.launch()
        model.setSmsEnabled(false)
        #expect(!model.smsEnabled && !model.settings.smsEnabled)
        model.setSmsEnabled(true)
        #expect(model.settings.smsEnabled)
        var opened = 0
        model.openMessagesWindow = { opened += 1 }
        model.showMessages(threadId: 7)
        #expect(opened == 1 && model.messages?.selection == 7)
        model.messagesWindowVisibilityChanged(true)
        #expect(model.messagesWindowOpen)
        model.messagesWindowVisibilityChanged(false)
        #expect(!model.messagesWindowOpen)
    }

    @Test("Settings › Messages: the reason SMS can't work with the phone, contacts hint, resync only when connected")
    func messagesPaneState() throws {
        let model = makeModel()
        model.launch()
        try model.completePairing(PairingControllerTests.result(name: "Pixel của Lan"))
        #expect(model.smsUnavailableReason == nil && !model.phoneMissesContactsPermission && !model.canResyncSms)
        model.updatePairRecord { $0.peerCapability = Self.capability(smsOn: false, missing: []) }
        #expect(model.smsUnavailableReason == L10n.Pairing.reasonOffOnDevice(deviceName: "Pixel của Lan"))
        model.updatePairRecord {
            $0.peerCapability = Self.capability(smsOn: true, missing: ["android.permission.READ_SMS", "READ_CONTACTS"])
        }
        #expect(model.smsUnavailableReason == L10n.Pairing.reasonMissingSmsPermission)
        #expect(model.phoneMissesContactsPermission)
        model.setSmsEnabled(false)
        #expect(model.smsUnavailableReason == nil) // the switch itself says it is off
        #expect(!SmsSyncSection.relative(1_727_150_000_000, now: Date(timeIntervalSince1970: 1_727_150_300)).isEmpty)
    }

    static func capability(smsOn: Bool, missing: [String]) -> CapabilityData {
        CapabilityData(appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
                       features: Features(sms: SmsFeature(enabled: smsOn, canSend: true)), permissionsMissing: missing)
    }

    static func message(_ id: Int, ts: Int64) -> SmsMessageData {
        SmsMessageData(messageKey: "sms:\(id)", threadId: 7, address: address, body: "Chiều nay 3h họp nhé", box: .inbox,
                       ts: ts, read: false, subId: 1, localId: nil)
    }

    static func new(_ id: Int, ts: Int64) -> IncomingEnvelope {
        let data = SmsNewData(message: message(id, ts: ts),
                              thread: SmsThreadData(threadId: 7, addresses: [address], displayName: "Nguyễn Văn A",
                                                    snippet: "Chiều nay 3h họp nhé", lastTs: ts, unreadCount: 1))
        let payload = Payload(op: SmsOp.new.rawValue, data: (try? HLJSON.convert(from: data)) ?? .emptyObject)
        return IncomingEnvelope(id: HLUUID.v7(), type: .sms, ts: HLUUID.currentTimeMs(), body: .json(payload))
    }
}
