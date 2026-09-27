import Foundation
import HLAppCore
import HLCallNotifications
import HLProtocol
import HLTransport
@testable import HLMacUI

/// The Mac's call surfaces recorded instead of shown: panel, ringtone, Focus and notifications.
@MainActor
final class CallStubs {
    let presenter = StubCallPresenter()
    let ringtone = StubRingtone()
    let focus = StubFocus()
    let notifier = StubCallNotifier()

    func make(settings: AppSettings, controller: CallController = CallController()) -> MacCalls {
        MacCalls(settings: settings, presenter: presenter, ringtone: ringtone, focus: focus, notifier: notifier,
                 controller: controller)
    }
}

@MainActor
final class StubCallPresenter: CallPanelPresenting {
    private(set) var isShown = false
    private(set) var shownCallId: String?
    private(set) var announcements: [String] = []

    func show(callId: String, announce: String?) {
        isShown = true
        shownCallId = callId
        if let announce { announcements.append(announce) }
    }

    func hide() {
        isShown = false
        shownCallId = nil
    }
}

@MainActor
final class StubRingtone: RingtonePlaying {
    private(set) var isPlaying = false
    private(set) var starts = 0

    func start() {
        isPlaying = true
        starts += 1
    }

    func stop() {
        isPlaying = false
    }
}

@MainActor
final class StubFocus: FocusReading {
    var state = FocusState.off
    var isAuthorized = true
    private(set) var requests = 0

    func requestAuthorization() async -> Bool {
        requests += 1
        return isAuthorized
    }
}

@MainActor
final class StubCallNotifier: CallNotifying {
    private(set) var incoming: [String: CallNotificationContent.Level] = [:]
    private(set) var missed: [(MissedCall, Bool)] = []
    private(set) var removedMissed: [Int64?] = []
    private(set) var removedAll = 0

    func postIncoming(_ state: CallStateData, pairId: String, level: CallNotificationContent.Level) {
        incoming[state.callId] = level
    }

    func removeIncoming(callId: String) {
        incoming[callId] = nil
    }

    func postMissed(_ missed: MissedCall, canMessage: Bool) {
        self.missed.append((missed, canMessage))
    }

    func removeMissed(pairId: String, entryId: Int64?) {
        removedMissed.append(entryId)
    }

    func removeAllCalls() {
        removedAll += 1
        incoming.removeAll()
    }
}

/// The phone's side of `call_event/action`: answers every command `ok`, or never answers.
final class OkCallPeer: CallPeer, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [CallActionRequest] = []
    let answers: Bool

    init(answers: Bool = true) {
        self.answers = answers
    }

    var route: ConnectionRoute { .lan }
    var sent: [CallActionRequest] { lock.withLock { actions } }

    func request<Body: Encodable & Sendable>(_ op: CallEventOp, data: Body, id: String,
                                             timeout: Duration) async throws -> Ack {
        if let action = try? HLJSON.convert(HLJSON.convert(from: data), to: CallActionRequest.self) {
            lock.withLock { actions.append(action) }
        }
        guard answers else {
            try await Task.sleep(for: timeout)
            throw SessionError.timedOut
        }
        return .success(re: id)
    }
}

enum MacCallSamples {
    static let callId = "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"

    static func ringing(number: String? = "+84900000123") -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .ringing, number: number,
                      displayName: number == nil ? nil : "Nguyễn Văn A", presentation: number == nil ? .unknown : .allowed,
                      subId: 1, simLabel: nil, startedAt: 1_727_150_400_123,
                      controls: CallControls(answer: true, reject: true))
    }

    static func offhook() -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .offhook, number: "+84900000123",
                      displayName: "Nguyễn Văn A", presentation: .allowed, startedAt: 1_727_150_400_123,
                      answeredAt: 1_727_150_405_000, controls: CallControls(end: true))
    }

    /// A second call rings during the answered one: the context stays the first call, `waiting = true`, no controls
    /// (CALL-01 API 1, E9).
    static func waiting() -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .ringing, waiting: true, number: "+84900000123",
                      displayName: "Nguyễn Văn A", presentation: .allowed, waitingNumber: "+84900000789",
                      startedAt: 1_727_150_400_123, answeredAt: 1_727_150_405_000, controls: .none)
    }

    static func idleMissed(number: String? = nil) -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .idle, number: number, displayName: nil,
                      presentation: number == nil ? .unknown : .allowed, startedAt: 1_727_150_400_123,
                      endedAt: 1_727_150_425_000, endReason: .missed, controls: .none)
    }

    static func capability(callLog: Bool = true) -> CapabilityData {
        CapabilityData(appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
                       features: Features(sms: SmsFeature(enabled: true, canSend: true),
                                          call: CallFeature(enabled: true, canAnswer: true, canEnd: true,
                                                            callerId: callLog)))
    }
}
