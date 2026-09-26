import Foundation
import HLAppCore
import HLCrypto
import HLLocalization
import HLProtocol
import HLSMS
import HLSMSNotifications
import HLTransport
import Testing
@testable import HLiOSUI

@Suite("iPhone and iPad app model")
@MainActor
struct IOSAppModelTests {
    static let address = "+84900000123"

    static func smsNew(_ id: Int, thread: Int64 = 7, ts: Int64) -> IncomingEnvelope {
        let data = SmsNewData(message: SmsMessageData(messageKey: "sms:\(id)", threadId: thread, address: address,
                                                      body: "Chiều nay 3h họp nhé", box: .inbox, ts: ts, read: false,
                                                      subId: 1),
                              thread: SmsThreadData(threadId: thread, addresses: [address], displayName: "Nguyễn Văn A",
                                                    snippet: "Chiều nay 3h họp nhé", lastTs: ts, unreadCount: 1))
        let payload = Payload(op: SmsOp.new.rawValue, data: (try? HLJSON.convert(from: data)) ?? .emptyObject)
        return IncomingEnvelope(id: HLUUID.v7(), type: .sms, ts: HLUUID.currentTimeMs(), body: .json(payload))
    }

    @Test("Launch creates the keys (SET-03 step 2), the SMS screens and the clipboard; setup completes once")
    func launch() {
        let model = makeIOSModel()
        model.launch()
        #expect(model.phase == .ready && model.deviceId != nil && model.messages != nil)
        #expect(!model.setupCompleted)
        model.completeSetup()
        #expect(model.setupCompleted)
        #expect(model.device.capability(settings: model.settings).features.sms?.notify == true)
        model.setSmsNotify(false) // iOS: sms.notify is in the capability (the phone pushes only when on)
        #expect(model.device.capability(settings: model.settings).features.sms?.notify == false)
    }

    @Test("A Keychain that refuses the keys → keysFailed with Try Again (SET-03 E1)")
    func keysFailed() {
        let model = makeIOSModel(secrets: FailingSecretStore())
        model.launch()
        #expect(model.phase == .keysFailed)
    }

    @Test("Pairing: the send card and the banner name the phone; {device_type} stays iPhone or iPad")
    func pairingAndClipboardTexts() throws {
        let pasteboard = StubIOSPasteboard()
        let model = makeIOSModel(pasteboard: pasteboard)
        model.launch()
        #expect(model.sendCardTitle == nil && model.pairingIdentity()?.platform == .ios)
        try model.completePairing(pairingResult())
        #expect(model.sendCardTitle == L10n.Clipboard.sendToPhoneTitle(deviceName: "Pixel của Lan"))
        pasteboard.userCopied()
        model.sceneBecameActive()
        #expect(model.unsentLocalContent)
        #expect(model.unsentBannerText(deviceType: "iPad", hasImages: true)
            == L10n.Clipboard.newImageBanner(deviceType: "iPad", deviceName: "Pixel của Lan"))
        model.dismissUnsentBanner()
        #expect(!model.unsentLocalContent && model.unsentBannerText(deviceType: "iPhone", hasImages: false) == nil)
        #expect(pasteboard.contentReads == 0) // CLIP-04: never a content read
    }

    @Test("A paste while the phone is away says Not connected to the phone (E5); unsupported content says so (E3)")
    func pasteOffline() async throws {
        let model = makeIOSModel()
        model.launch()
        try model.completePairing(pairingResult())
        model.sendPasted([NSItemProvider(object: "Hẹn 3h" as NSString)])
        #expect(await eventually { model.clipboardNotice == .notConnectedWillSend })
        #expect(model.clipboardNotice?.iosText == L10n.Clipboard.notConnectedToPhone)
        model.sendPasted([NSItemProvider()])
        #expect(await eventually { model.clipboardNotice == .unsupportedContent })
        #expect(ClipboardNotice.textTooLarge.iosText == L10n.Error.clipContentTooLarge)
    }

    @Test("sms/new while open: stored, counted on the tab and the icon, no notification; read → notifications go")
    func incomingSms() async throws {
        let notifications = StubIOSNotifications()
        let model = makeIOSModel(notifications: notifications)
        model.launch()
        try model.completePairing(pairingResult())
        let messages = try #require(model.messages)
        await model.handle(.message(Self.smsNew(1, ts: 1_000)))
        #expect(await eventually { model.unreadThreads == 1 && notifications.badges.last == 1 })
        #expect(await eventually { messages.threads.map(\.threadId) == [7] })
        let info = try #require(SmsNotificationInfo([SmsNotificationKeys.pairId: messages.pairId ?? "",
                                                     SmsNotificationKeys.threadId: NSNumber(value: 7)]))
        await model.handleSmsNotification(.markRead(info))
        #expect(await eventually { model.unreadThreads == 0 && notifications.badges.last == 0 })
        #expect(notifications.removed.contains { $0.threadId == 7 && $0.upToTs == nil })
        await model.handleSmsNotification(.open(info))
        #expect(model.selectedTab == .messages && messages.selection == 7)
    }

    @Test("Quick reply without the phone: waits in the outbox and says Not sent yet (SMS-04 API 5 logic 3)")
    func quickReplyNotSent() async throws {
        let notifications = StubIOSNotifications()
        let model = makeIOSModel(notifications: notifications)
        model.quickReplyDeadline = .milliseconds(200)
        model.launch()
        try model.completePairing(pairingResult())
        let messages = try #require(model.messages)
        let pairId = try #require(messages.pairId)
        let info = try #require(SmsNotificationInfo([SmsNotificationKeys.pairId: pairId,
                                                     SmsNotificationKeys.threadId: NSNumber(value: 7),
                                                     SmsNotificationKeys.address: Self.address]))
        model.sceneEnteredBackground()
        await model.handleSmsNotification(.reply(info, text: "  Ok, 3h nhé  "))
        #expect(notifications.notSentYet == [7])
        let pending = try await messages.store.pending(pairId: pairId)
        #expect(pending.map(\.body) == ["Ok, 3h nhé"])
        await model.handleSmsNotification(.reply(info, text: "   ")) // logic 4: empty text is ignored
        #expect(try await messages.store.pending(pairId: pairId).count == 1)
    }

    @Test("The push token goes to the relay as lowercase hex with the topic, not while the relay is off")
    func pushToken() async throws {
        let relay = ScriptedRelayAPI()
        let model = makeIOSModel(relay: relay)
        model.launch()
        model.setRelayEnabled(false)
        model.pushTokenReceived(Data([0xAB, 0x01, 0xFF]))
        try? await Task.sleep(for: .milliseconds(600))
        #expect(relay.pushTokens.isEmpty)
        model.setRelayEnabled(true)
        #expect(await eventually { relay.pushTokens.count == 1 })
        let request = try #require(relay.pushTokens.first)
        #expect(request.token == "ab01ff" && request.provider == .apnsSandbox && request.topic == "app.handlive.ios")
    }

    @Test("Delete All: revoke_pairs=true, every notification gone, a fresh install's keys; E7 when offline")
    func deleteAll() async throws {
        let relay = ScriptedRelayAPI()
        let notifications = StubIOSNotifications()
        let model = makeIOSModel(notifications: notifications, relay: relay)
        model.launch()
        try model.completePairing(pairingResult())
        model.completeSetup()
        let oldDevice = model.deviceId
        relay.reachable = false
        #expect(await model.deleteAllData() == .serverUnreachable)
        #expect(model.pairedDevice != nil)
        relay.reachable = true
        var erased = false
        model.didEraseAllData = { erased = true }
        #expect(await model.deleteAllData() == .deleted)
        #expect(relay.calls.contains("deleteDevice revoke_pairs=true"))
        #expect(erased && model.pairedDevice == nil && !model.setupCompleted && model.deviceId != oldDevice)
        #expect(notifications.removedEverything == 1)
    }

    @Test("Remove from Server keeps the pair with relay_registered = 0 and turns the relay off")
    func removeFromServer() async throws {
        let relay = ScriptedRelayAPI()
        let model = makeIOSModel(relay: relay)
        model.launch()
        try model.completePairing(pairingResult())
        model.updatePairRecord { $0.relayRegistered = true }
        #expect(await model.removeFromServer() == .removed)
        #expect(relay.calls.last == "deleteDevice revoke_pairs=false")
        #expect(model.pairedDevice?.relayRegistered == false && !model.relayEnabled)
    }
}

/// A secret store whose Keychain calls fail, like errSecMissingEntitlement (SET-03 E1).
struct FailingSecretStore: SecretStore {
    func save(_ secret: Data, account: String) throws { throw CryptoError.keychain(status: -34018) }
    func load(account: String) throws -> Data? { throw CryptoError.keychain(status: -34018) }
    func delete(account: String) throws { throw CryptoError.keychain(status: -34018) }
    func deleteAll() throws { throw CryptoError.keychain(status: -34018) }
}

@Suite("iPhone and iPad setup (SET-03)")
@MainActor
struct IOSSetupFlowTests {
    @Test("Welcome → notifications (asked once) → local network → limits → done; refusals show their guides")
    func steps() async {
        let notifications = StubIOSNotifications()
        let model = makeIOSModel(notifications: notifications)
        model.launch()
        var registered = 0
        let flow = IOSSetupFlow(model: model, probeLocalNetwork: { .ready }, registerForPush: { registered += 1 })
        #expect(flow.step == .welcome)
        flow.start()
        await flow.continueFromNotifications()
        #expect(flow.step == .localNetwork && notifications.requests == 1)
        await flow.continueFromLocalNetwork()
        #expect(flow.step == .limits)
        flow.finish()
        #expect(model.setupCompleted && registered == 1)

        let denied = StubIOSNotifications()
        denied.answer = .denied
        let refusing = makeIOSModel(notifications: denied)
        refusing.launch()
        let guides = IOSSetupFlow(model: refusing, probeLocalNetwork: { .localNetworkDenied })
        guides.start()
        await guides.continueFromNotifications()
        #expect(guides.step == .notificationsDenied && refusing.notificationPermission == .denied)
        guides.afterNotificationsGuide()
        await guides.continueFromLocalNetwork()
        #expect(guides.step == .localNetworkDenied)
        guides.afterLocalNetworkGuide()
        #expect(guides.step == .limits)
    }
}
