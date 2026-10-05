import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLSMS
import Testing
@testable import HLiOSUI

@Suite("iPhone and iPad: SMS and calls notified during the background grace (CONN-02 E3)")
@MainActor
struct IOSGraceNotificationTests {
    @Test("SMS during the grace gets the notification the push would show; none in the foreground")
    func smsDuringGrace() async throws {
        let tasks = FakeBackgroundTasks()
        let notifications = StubIOSNotifications()
        let (model, _) = try await IOSBackgroundGraceTests.pairedAndConnected(tasks: tasks, notifications: notifications)
        model.sceneEnteredBackground()
        await model.handle(.message(IOSAppModelTests.smsNew(1, ts: 1_000)))
        #expect(await eventually { notifications.postedSms == ["sms:1"] })
        model.sceneBecameActive()
        await model.handle(.message(IOSAppModelTests.smsNew(2, ts: 2_000)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(notifications.postedSms == ["sms:1"])
    }

    @Test("A ringing call during the grace is notified once; it goes when the call stops ringing")
    func callDuringGrace() async throws {
        let tasks = FakeBackgroundTasks()
        let stub = StubIOSCallNotifications()
        let (model, _) = try await IOSBackgroundGraceTests.pairedAndConnected(tasks: tasks, calls: stub)
        model.calls.controller.connected(peer: OkCallPeer(), capability: IOSCallSamples.capability())
        model.sceneEnteredBackground()
        model.calls.controller.apply(IOSCallSamples.ringing(), envelopeTs: 100)
        model.calls.controller.apply(IOSCallSamples.ringing(), envelopeTs: 150)
        #expect(stub.incoming == [IOSCallSamples.callId])
        model.calls.controller.apply(IOSCallSamples.offhook(), envelopeTs: 200)
        #expect(stub.removedIncoming.contains(IOSCallSamples.callId))
    }

    @Test("Grace notifications: locked shows the push's generic text; unlocked follows sms.preview")
    func lockScreenRules() throws {
        let new = SmsNewData(message: SmsMessageData(messageKey: "sms:1", threadId: 7, address: "+84900000123",
                                                     body: "Mã OTP 123456", box: .inbox, ts: 1, read: false, subId: 1),
                             thread: SmsThreadData(threadId: 7, addresses: ["+84900000123"], displayName: "Ngân hàng",
                                                   snippet: "", lastTs: 1, unreadCount: 1))
        let locked = GraceNotificationContent.sms(new, pairId: "p", simLabel: nil, showPreview: true, unlocked: false)
        #expect(locked.title.isEmpty && locked.body == L10n.Push.smsNew && locked.categoryIdentifier.isEmpty)
        let hidden = GraceNotificationContent.sms(new, pairId: "p", simLabel: nil, showPreview: false, unlocked: true)
        #expect(hidden.body == L10n.Sms.notificationHiddenBody && !hidden.body.contains("123456"))
        let shown = GraceNotificationContent.sms(new, pairId: "p", simLabel: nil, showPreview: true, unlocked: true)
        #expect(shown.body == "Mã OTP 123456")
        let call = GraceNotificationContent.incomingCall(IOSCallSamples.ringing(), pairId: "p", unlocked: false,
                                                         nowMs: IOSCallSamples.ringing().startedAt)
        #expect(call.title.isEmpty && call.body == L10n.Push.callIncoming && call.categoryIdentifier.isEmpty)
        let open = GraceNotificationContent.incomingCall(IOSCallSamples.ringing(), pairId: "p", unlocked: true,
                                                         nowMs: IOSCallSamples.ringing().startedAt)
        #expect(!open.title.isEmpty && !open.categoryIdentifier.isEmpty)
    }
}
