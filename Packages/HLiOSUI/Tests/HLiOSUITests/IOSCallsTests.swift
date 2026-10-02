import Foundation
import HLAppCore
import HLCallNotifications
import HLCrypto
import HLLocalization
import HLProtocol
import HLSMS
import HLTransport
import Testing
import UserNotifications
@testable import HLiOSUI

/// CALL-01 steps 8 and 12, CALL-02 flow B and CALL-04 on iPhone and iPad: the in-app banner, the incoming-call
/// notifications that go when the call moves on, "Decline" and "Message" from notifications, missed calls, and the
/// extension's copy of the phone's SMS send capability.
@Suite("iPhone and iPad app model: calls")
@MainActor
struct IOSCallsTests {
    static let prk = Data(repeating: 0x99, count: 32) // pairingResult()'s

    func ready(_ stub: StubIOSCallNotifications, peer: OkCallPeer? = OkCallPeer(),
               capability: CapabilityData = IOSCallSamples.capability()) throws -> IOSAppModel {
        let model = makeIOSModel(calls: stub)
        model.launch()
        try model.completePairing(pairingResult())
        if let peer { model.calls.controller.connected(peer: peer, capability: capability) }
        return model
    }

    /// An APNs payload as the relay delivers it: `p`, and `hl` sealed with the pair's `K_push`.
    static func push(_ state: CallStateData, pairId: String, locKey: String = "push.call_incoming",
                     ts: Int64 = HLUUID.currentTimeMs()) throws -> [AnyHashable: Any] {
        let payload = Payload(op: CallEventOp.state.rawValue, data: try HLJSON.convert(from: state))
        let envelope = try PushEnvelope.seal(type: .callEvent, plaintext: try payload.encoded(), prk: prk, ts: ts)
        return ["aps": ["alert": ["loc-key": locKey]], "p": pairId, "hl": Base64Coding.encodeB64(envelope.wireData())]
    }

    @Test("Ringing: the banner with VoiceOver; answered on the phone: the banner and the notification go")
    func banner() throws {
        let stub = StubIOSCallNotifications()
        let model = try ready(stub)
        var announced: [String] = []
        model.calls.announce = { announced.append($0) }
        model.calls.controller.apply(IOSCallSamples.ringing(), envelopeTs: 100)
        #expect(model.calls.banner?.callId == IOSCallSamples.callId)
        #expect(announced == [L10n.A11y.callIncomingFrom(caller: "Nguyễn Văn A")])
        model.calls.controller.apply(IOSCallSamples.ringing(), envelopeTs: 150) // an update: no second announcement
        #expect(announced.count == 1 && stub.removedIncoming.isEmpty)
        model.calls.controller.apply(IOSCallSamples.offhook(), envelopeTs: 200)
        #expect(model.calls.banner == nil && stub.removedIncoming == [IOSCallSamples.callId])
    }

    @Test("A call first heard of in another state loses its notification at once; call notifications off: no banner")
    func notRinging() throws {
        let stub = StubIOSCallNotifications()
        let model = try ready(stub)
        model.calls.controller.apply(IOSCallSamples.offhook(), envelopeTs: 100)
        model.calls.controller.apply(IOSCallSamples.offhook(), envelopeTs: 110)
        #expect(stub.removedIncoming == [IOSCallSamples.callId] && model.calls.banner == nil)
        let quiet = try ready(StubIOSCallNotifications())
        quiet.calls.setCallNotify(false)
        quiet.calls.controller.apply(IOSCallSamples.ringing(), envelopeTs: 100)
        #expect(quiet.calls.banner == nil && quiet.calls.controller.call != nil)
        #expect(quiet.device.capability(settings: quiet.settings).features.call?.notify == false)
    }

    @Test("A waiting call shows the waiting caller without Decline")
    func waiting() throws {
        let model = try ready(StubIOSCallNotifications())
        var announced: [String] = []
        model.calls.announce = { announced.append($0) }
        model.calls.controller.apply(IOSCallSamples.ringing(waiting: true), envelopeTs: 100)
        #expect(model.calls.banner?.phase == .waiting && model.calls.banner?.state.controls.reject == false)
        #expect(announced == [L10n.A11y.callIncomingFrom(caller: "090 000 0789")])
    }

    @Test("Decline on the banner sends reject once, from the banner")
    func declineOnBanner() async throws {
        let peer = OkCallPeer()
        let model = try ready(StubIOSCallNotifications(), peer: peer)
        model.calls.controller.apply(IOSCallSamples.ringing(), envelopeTs: 100)
        model.calls.decline()
        #expect(await eventually { peer.sent.map(\.action) == [.reject] })
        model.calls.decline() // locked until the ack or the next state
        #expect(peer.sent.count == 1)
    }

    @Test("Decline from the notification: accepted removes it; no phone in time says so; over 90 s only removes it")
    func declineFromNotification() async throws {
        let stub = StubIOSCallNotifications()
        let peer = OkCallPeer()
        let model = try ready(stub, peer: peer)
        let pairId = try #require(model.pairedDevice?.pairId)
        let now = HLUUID.currentTimeMs()
        await model.handleCallNotification(.reject(pairId: pairId, callId: IOSCallSamples.callId, startedAt: now))
        #expect(peer.sent.map(\.action) == [.reject] && stub.removedIncoming == [IOSCallSamples.callId])
        #expect(stub.declineFailed.isEmpty)
        await model.handleCallNotification(.reject(pairId: pairId, callId: "old", startedAt: now - 91_000))
        #expect(peer.sent.count == 1 && stub.removedIncoming.last == "old")

        let silent = StubIOSCallNotifications()
        let offline = try ready(silent, peer: nil)
        offline.callRejectDeadline = .milliseconds(300)
        let offlinePair = try #require(offline.pairedDevice?.pairId)
        await offline.handleCallNotification(.reject(pairId: offlinePair, callId: IOSCallSamples.callId, startedAt: now))
        #expect(silent.declineFailed == [IOSCallSamples.callId] && silent.removedIncoming.isEmpty)
    }

    @Test("Open: an incoming call push becomes the banner and no system banner; a missed call stays in the list only")
    func foreground() throws {
        let model = try ready(StubIOSCallNotifications(), peer: nil)
        let pairId = try #require(model.pairedDevice?.pairId)
        let userInfo = try Self.push(IOSCallSamples.ringing(), pairId: pairId)
        let options = model.foregroundPresentation(info: CallNotificationInfo(userInfo),
                                                   push: PushAlertFields(userInfo: userInfo))
        #expect(options == [] && model.calls.banner?.callId == IOSCallSamples.callId)
        let missed = try Self.push(IOSCallSamples.idleMissed(), pairId: pairId, locKey: "push.call_missed")
        #expect(model.foregroundPresentation(info: nil, push: PushAlertFields(userInfo: missed)) == [.list])
        let posted = CallNotificationInfo.missed(pairId: pairId, entryId: 7, callId: nil, number: nil, subId: nil)
        #expect(model.foregroundPresentation(info: posted, push: nil) == [.list])
        #expect(model.foregroundPresentation(info: nil, push: nil) == nil) // not a call: the SMS rules apply
    }

    @Test("A generic incoming push opens with the pair's key for its removal; background forgets the call")
    func readerAndBackground() throws {
        let stub = StubIOSCallNotifications()
        let model = try ready(stub)
        let pairId = try #require(model.pairedDevice?.pairId)
        model.sceneBecameActive()
        let reader = try #require(stub.lastReader)
        #expect(stub.staleChecks.count == 1)
        #expect(reader(try Self.push(IOSCallSamples.ringing(), pairId: pairId))?.callId == IOSCallSamples.callId)
        #expect(reader(try Self.push(IOSCallSamples.idleMissed(), pairId: pairId)) == nil)
        model.calls.controller.apply(IOSCallSamples.ringing(), envelopeTs: 100)
        model.sceneEnteredBackground()
        #expect(model.calls.banner == nil && model.calls.controller.call == nil)
    }

    @Test("Missed without the call log: notified, without Message when there is no number")
    func missedFlowA() throws {
        let stub = StubIOSCallNotifications()
        let model = try ready(stub, capability: IOSCallSamples.capability(callLog: false))
        model.calls.controller.apply(IOSCallSamples.ringing(number: nil), envelopeTs: 100)
        model.calls.controller.apply(IOSCallSamples.idleMissed(), envelopeTs: 200)
        #expect(stub.missed.count == 1 && stub.missed.first?.1 == false)
        #expect(stub.missed.first?.0.caller == .unknownCaller)
    }

    @Test("Message on a missed call: queued for the number; without the phone it says Not sent yet")
    func message() async throws {
        let stub = StubIOSCallNotifications()
        let model = try ready(stub, peer: nil)
        model.quickReplyDeadline = .milliseconds(200)
        let pairId = try #require(model.pairedDevice?.pairId)
        await model.handleCallNotification(.message(pairId: pairId, entryId: 5120, callId: nil, number: "+84900000123",
                                                    subId: 1, text: "  Gọi lại sau  "))
        #expect(stub.replyNotSent == ["5120"])
        let messages = try #require(model.messages)
        let queued = try await messages.store.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM sms_outbox WHERE pair_id = ?", arguments: [pairId])
        }
        #expect(queued == "Gọi lại sau")
        await model.handleCallNotification(.message(pairId: pairId, entryId: 5121, callId: nil, number: "+84900000123",
                                                    subId: 1, text: "   "))
        #expect(stub.replyNotSent.count == 1) // empty after trimming: ignored
    }

    @Test("The extension's copy of the phone's SMS send capability follows the capability and goes with the pair")
    func peerCanSend() async throws {
        let model = try ready(StubIOSCallNotifications(), peer: nil)
        let pairId = try #require(model.pairedDevice?.pairId)
        #expect(model.settings.peerCanSend(pairId: pairId) == nil) // no capability yet: no Message
        await model.handle(.capabilityUpdated(IOSCallSamples.capability()))
        #expect(model.settings.peerCanSend(pairId: pairId) == true)
        await model.handle(.capabilityUpdated(IOSCallSamples.capability(canSend: false)))
        #expect(model.settings.peerCanSend(pairId: pairId) == false)
        await model.handle(.capabilityUpdated(IOSCallSamples.capability()))
        model.setSmsEnabled(false)
        #expect(model.settings.peerCanSend(pairId: pairId) == false)
        await model.unpair()
        #expect(model.settings.peerCanSend(pairId: pairId) == nil)
    }

    @Test("Settings: Calls off removes every call notification; the reasons calls don't work")
    func settings() throws {
        let stub = StubIOSCallNotifications()
        let model = try ready(stub)
        #expect(model.callsFeatureReason == nil) // no capability stored yet
        model.calls.setCallsEnabled(false)
        #expect(stub.removedAll == 1 && !model.settings.callsEnabled)
        #expect(model.callsFeatureReason == L10n.Pairing.reasonOffOnDevice(deviceName: model.device.name))
        #expect(model.device.capability(settings: model.settings).features.call?.enabled == false)
    }

    @Test("Calls from other apps are for the Mac: iPhone and iPad say app_calls false and ignore an app_call message")
    func appCallsAreMacOnly() throws {
        let stub = StubIOSCallNotifications()
        let model = try ready(stub)
        #expect(model.device.capability(settings: model.settings).features.call?.appCalls == false)
        let data = AppCallData(callId: IOSCallSamples.callId, app: AppCallApp(package: "org.telegram.messenger",
                                                                              label: "Telegram"),
                               caller: "Nguyễn Văn A", state: .ringing,
                               controls: AppCallControls(answer: true, decline: true), startedAt: 1_727_150_400_123)
        let envelope = IncomingEnvelope(id: HLUUID.v7(), type: .callEvent, ts: 100,
                                        body: .json(Payload(op: CallEventOp.appCall.rawValue,
                                                            data: try HLJSON.convert(from: data))))
        model.calls.linkEvent(.message(envelope))
        #expect(model.calls.controller.call == nil && model.calls.banner == nil)
        #expect(stub.removedIncoming.isEmpty && stub.removedAll == 0)
    }
}
