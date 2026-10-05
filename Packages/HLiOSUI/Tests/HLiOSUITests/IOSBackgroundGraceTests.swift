import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLSMS
import HLSMSNotifications
import HLTransport
import SwiftUI
import Testing
@preconcurrency import UserNotifications
@testable import HLiOSUI

@Suite("iPhone and iPad: the session in the background grace (CONN-02 E3)")
@MainActor
struct IOSBackgroundGraceTests {
    /// A model with a live session (no manager running) whose connection is the recorder.
    static func connected(tasks: FakeBackgroundTasks, grace: Duration = .milliseconds(150))
        -> (IOSAppModel, RecordingLifecycle) {
        let model = makeIOSModel(backgroundTasks: tasks)
        let recorder = RecordingLifecycle()
        model.hold.lifecycle = recorder
        model.backgroundGrace = grace
        model.link = LinkStatus(state: .connected(.lan))
        return (model, recorder)
    }

    /// A launched and paired model (SMS, calls) with a live session, once the idle manager has settled.
    static func pairedAndConnected(tasks: FakeBackgroundTasks, notifications: StubIOSNotifications = StubIOSNotifications(),
                                   calls: StubIOSCallNotifications = StubIOSCallNotifications(),
                                   grace: Duration = .seconds(5)) async throws -> (IOSAppModel, RecordingLifecycle) {
        let model = makeIOSModel(notifications: notifications, calls: calls, backgroundTasks: tasks)
        let recorder = RecordingLifecycle()
        model.hold.lifecycle = recorder
        model.backgroundGrace = grace
        model.launch()
        try model.completePairing(pairingResult())
        try await Task.sleep(for: .milliseconds(200))
        model.link = LinkStatus(state: .connected(.lan))
        return (model, recorder)
    }

    @Test("Background with a session: it stays for the grace, then bye, then the task ends")
    func graceThenBye() async {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = Self.connected(tasks: tasks)
        model.sceneEnteredBackground()
        #expect(tasks.begun.count == 1 && model.notifiesInBackground)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.log.isEmpty && tasks.ended.isEmpty)
        #expect(await eventually { tasks.ended == tasks.begun })
        #expect(await recorder.log == ["sleep"])
        #expect(!model.notifiesInBackground)
    }

    @Test("Back before the grace ends: the task ends, no bye, the session stays")
    func backBeforeDeadline() async {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = Self.connected(tasks: tasks)
        model.sceneEnteredBackground()
        model.sceneBecameActive()
        #expect(tasks.ended == tasks.begun && tasks.ended.count == 1)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await recorder.log == ["wake"]) // a no-op on a live session (see the transport test)
    }

    @Test("Back after the bye went out: CONN-01 runs only once the close is done")
    func backAfterDeadline() async {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = Self.connected(tasks: tasks, grace: .milliseconds(20))
        model.sceneEnteredBackground()
        #expect(await eventually { tasks.ended.count == 1 })
        model.sceneBecameActive()
        #expect(await eventuallyAsync { await recorder.log.count == 2 })
        #expect(await recorder.log == ["sleep", "wake"])
    }

    @Test("The system's time is up: the task ends at once, the bye follows")
    func expiration() async {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = Self.connected(tasks: tasks, grace: .seconds(5))
        model.sceneEnteredBackground()
        tasks.expire()
        #expect(tasks.ended == tasks.begun && tasks.ended.count == 1)
        #expect(await eventuallyAsync { await recorder.log == ["sleep"] })
    }

    @Test("The bye hangs after the deadline: iOS's expiration still ends the task at once")
    func hangingCloseThenExpiration() async {
        let tasks = FakeBackgroundTasks()
        let (model, _) = Self.connected(tasks: tasks, grace: .milliseconds(20))
        let hanging = HangingLifecycle()
        model.hold.lifecycle = hanging
        model.hold.closeWaitCap = .seconds(30)
        model.sceneEnteredBackground()
        #expect(await eventuallyAsync { await hanging.log == ["sleep"] })
        #expect(tasks.ended.isEmpty) // waiting for the close
        tasks.expire()
        #expect(tasks.ended == tasks.begun && tasks.ended.count == 1)
        await hanging.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(tasks.ended.count == 1) // ended once
    }

    @Test("The bye hangs after the deadline: the task ends after the wait cap, the close goes on")
    func hangingCloseCapped() async {
        let tasks = FakeBackgroundTasks()
        let (model, _) = Self.connected(tasks: tasks, grace: .milliseconds(20))
        let hanging = HangingLifecycle()
        model.hold.lifecycle = hanging
        model.hold.closeWaitCap = .milliseconds(100)
        model.sceneEnteredBackground()
        #expect(await eventuallyAsync { await hanging.log == ["sleep"] })
        #expect(await eventually { tasks.ended == tasks.begun && tasks.ended.count == 1 })
        #expect(await hanging.log == ["sleep"]) // still closing
        await hanging.release()
        #expect(await eventuallyAsync { await hanging.log == ["sleep", "closed"] })
        tasks.expire() // a late expiration finds nothing left to end
        #expect(tasks.ended.count == 1)
    }

    @Test(".inactive (Control Center, the app switcher, Face ID) keeps the session: no task, no bye")
    func inactiveIsIgnored() async {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = Self.connected(tasks: tasks)
        model.scenePhaseChanged(.inactive)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(tasks.begun.isEmpty && model.inForeground)
        #expect(await recorder.log.isEmpty)
        model.scenePhaseChanged(.background) // the same switch does start the grace on .background
        #expect(tasks.begun.count == 1 && !model.inForeground)
    }

    @Test("Background task refused, or no session: close at once, no task left")
    func refusedOrNoSession() async {
        let refused = FakeBackgroundTasks()
        refused.refuses = true
        let (model, recorder) = Self.connected(tasks: refused)
        model.sceneEnteredBackground()
        #expect(await eventuallyAsync { await recorder.log == ["sleep"] })
        let tasks = FakeBackgroundTasks()
        let (offline, offlineRecorder) = Self.connected(tasks: tasks)
        offline.link = LinkStatus(state: .backoff)
        offline.sceneEnteredBackground()
        #expect(tasks.begun.isEmpty)
        #expect(await eventuallyAsync { await offlineRecorder.log == ["sleep"] })
    }

    @Test("The time iOS still gives, less 5 s, caps the grace")
    func remainingTimeCaps() async {
        let tasks = FakeBackgroundTasks()
        tasks.remaining = .milliseconds(5_050)
        let (model, recorder) = Self.connected(tasks: tasks, grace: .seconds(25))
        model.sceneEnteredBackground()
        #expect(await eventuallyAsync { await recorder.log == ["sleep"] })
        #expect(tasks.ended == tasks.begun)
    }

    @Test("Background, foreground, background: one bye, every task ended, only the latest grace counts")
    func quickSwitches() async {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = Self.connected(tasks: tasks, grace: .milliseconds(100))
        model.sceneEnteredBackground()
        model.sceneBecameActive()
        model.sceneEnteredBackground()
        #expect(tasks.begun.count == 2)
        #expect(await eventually { tasks.ended.count == 2 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await recorder.log == ["wake", "sleep"])
        #expect(Set(tasks.ended) == Set(tasks.begun))
    }

    @Test("The session drops during the grace: the grace lets go, the task ends, no reconnect in the background")
    func droppedDuringGrace() async {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = Self.connected(tasks: tasks, grace: .seconds(5))
        model.sceneEnteredBackground()
        await model.handle(.disconnected)
        #expect(tasks.ended == tasks.begun && tasks.ended.count == 1)
        #expect(await eventuallyAsync { await recorder.log == ["sleep"] })
        #expect(!model.notifiesInBackground)
    }

    @Test("A quick reply during the grace uses the held session; the last holder closes it")
    func quickReplyHoldsTheSession() async throws {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = try await Self.pairedAndConnected(tasks: tasks, grace: .milliseconds(100))
        model.quickReplyDeadline = .milliseconds(500)
        let messages = try #require(model.messages)
        let info = try #require(SmsNotificationInfo([SmsNotificationKeys.pairId: messages.pairId ?? "",
                                                     SmsNotificationKeys.threadId: NSNumber(value: 7),
                                                     SmsNotificationKeys.address: IOSAppModelTests.address]))
        model.sceneEnteredBackground()
        let reply = Task { await model.handleSmsNotification(.reply(info, text: "Ok")) }
        #expect(await eventually { tasks.ended.count == 1 }) // the grace ended under the reply
        #expect(await recorder.log.isEmpty) // no new connection, no bye while the reply holds it
        await reply.value
        #expect(await eventuallyAsync { await recorder.log == ["sleep"] })
    }

    @Test("iOS ends the grace while a reply holds the session: the grace lets go, the reply keeps it until done")
    func expirationUnderAReply() async throws {
        let tasks = FakeBackgroundTasks()
        let (model, recorder) = try await Self.pairedAndConnected(tasks: tasks)
        model.quickReplyDeadline = .milliseconds(300)
        let messages = try #require(model.messages)
        let info = try #require(SmsNotificationInfo([SmsNotificationKeys.pairId: messages.pairId ?? "",
                                                     SmsNotificationKeys.threadId: NSNumber(value: 7),
                                                     SmsNotificationKeys.address: IOSAppModelTests.address]))
        model.sceneEnteredBackground()
        let reply = Task { await model.handleSmsNotification(.reply(info, text: "Ok")) }
        try await Task.sleep(for: .milliseconds(50))
        tasks.expire()
        #expect(tasks.ended.count == 1)
        #expect(await recorder.log.isEmpty)
        await reply.value
        #expect(await eventuallyAsync { await recorder.log == ["sleep"] })
    }
}
