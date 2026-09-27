import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import Testing
import UserNotifications
@testable import HLCallNotifications

/// The workspace files the call tests read: `shared/schemas`, `shared/test-vectors`.
enum CallTestFiles {
    /// apple/Packages/HLCalls/Tests/HLCallNotificationsTests/<file> → the workspace root (six levels up).
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    static let schemasDirectory = root.appendingPathComponent("shared/schemas")
    static let vectorsDirectory = root.appendingPathComponent("shared/test-vectors")
}

/// CALL-01 API 6–7 and CALL-04 API 4: the content, categories and `userInfo` of call notifications, against
/// `call-notification.schema.json`.
@Suite("Call notification content")
struct CallNotificationTests {
    static let pairId = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f2a3b4c5d"
    static let callId = "0192f3f0-6a1b-7c2d-8e3f-4a5b6c7d8e90"
    static let startedAt: Int64 = 1_727_150_400_123

    /// As the phone reports it to an iPhone (Decline only); `answer` as to a Mac that may answer too.
    static func ringing(number: String? = "+84900000123", name: String? = "Nguyễn Văn A", sim: String? = "SIM 1",
                        presentation: CallPresentation = .allowed, answer: Bool = false) -> CallStateData {
        CallStateData(callId: callId, direction: .incoming, state: .ringing, number: number, displayName: name,
                      presentation: presentation, subId: sim == nil ? nil : 1, simLabel: sim, startedAt: startedAt,
                      controls: CallControls(answer: answer, reject: true))
    }

    let validator: SchemaValidator

    init() throws {
        validator = try SchemaValidator()
    }

    private func expectValid(_ content: CallNotificationContent, _ ref: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let errors = validator.errors(content.json, ref: ref)
        #expect(errors.isEmpty, "\(ref): \(errors)", sourceLocation: sourceLocation)
    }

    @Test("Mac, panel showing: passive, identifier = call_id, Answer and Decline, SIM label in the body")
    func incomingMac() {
        let content = CallNotificationBuilder.incoming(Self.ringing(answer: true), pairId: Self.pairId, platform: .mac,
                                                       level: .passive, nowMs: Self.startedAt + 100)
        #expect(content.identifier == Self.callId && content.title == "Nguyễn Văn A")
        #expect(content.body == L10n.Call.incomingBodySim(simLabel: "SIM 1"))
        #expect(content.categoryIdentifier == "HL_CALL_INCOMING_MAC" && content.threadIdentifier == "calls")
        #expect(content.interruptionLevel == .passive && !content.playsSound)
        #expect(content.info == .incoming(pairId: Self.pairId, callId: Self.callId, startedAt: Self.startedAt))
        expectValid(content, "call-notification.schema.json#/$defs/incoming")
        let focus = CallNotificationBuilder.incoming(Self.ringing(sim: nil, answer: true), pairId: Self.pairId,
                                                     platform: .mac, level: .timeSensitive, nowMs: Self.startedAt)
        #expect(focus.interruptionLevel == .timeSensitive && focus.playsSound && focus.body == L10n.Call.incomingBody)
        expectValid(focus, "call-notification.schema.json#/$defs/incoming")
    }

    @Test("Mac: no Answer and Decline unless the phone allows both — never a button that does nothing")
    func incomingMacWithoutButtons() {
        let declineOnly = CallNotificationBuilder.incoming(Self.ringing(), pairId: Self.pairId, platform: .mac,
                                                           level: .passive, nowMs: Self.startedAt)
        #expect(declineOnly.categoryIdentifier == nil && declineOnly.identifier == Self.callId)
        #expect(declineOnly.interruptionLevel == .passive)
        expectValid(declineOnly, "call-notification.schema.json#/$defs/incoming")
        let none = CallStateData(callId: Self.callId, direction: .incoming, state: .ringing, number: "+84900000123",
                                 displayName: nil, presentation: .allowed, startedAt: Self.startedAt, controls: .none)
        #expect(CallNotificationBuilder.incoming(none, pairId: Self.pairId, platform: .mac, level: .timeSensitive,
                                                 nowMs: Self.startedAt).categoryIdentifier == nil)
    }

    @Test("iPhone: HL_CALL_INCOMING with the system's identifier; a push over 60 s late has no button, level active")
    func incomingMobile() {
        let content = CallNotificationBuilder.incoming(Self.ringing(), pairId: Self.pairId, platform: .mobile,
                                                       level: .timeSensitive, nowMs: Self.startedAt + 2000)
        #expect(content.identifier == nil && content.categoryIdentifier == "HL_CALL_INCOMING")
        expectValid(content, "call-notification.schema.json#/$defs/incoming")
        let late = CallNotificationBuilder.incoming(Self.ringing(), pairId: Self.pairId, platform: .mobile,
                                                    level: .timeSensitive, nowMs: Self.startedAt + 61_000)
        #expect(late.categoryIdentifier == nil && late.interruptionLevel == .active && !late.playsSound)
        #expect(late.body == L10n.Call.incomingLate(time: CallNames.time(Self.startedAt)))
        expectValid(late, "call-notification.schema.json#/$defs/incoming")
        // The phone may not decline for us (ANSWER_PHONE_CALLS missing): no "Decline".
        let locked = CallStateData(callId: Self.callId, direction: .incoming, state: .ringing, number: "+84900000123",
                                   displayName: nil, presentation: .allowed, startedAt: Self.startedAt, controls: .none)
        let noButton = CallNotificationBuilder.incoming(locked, pairId: Self.pairId, platform: .mobile,
                                                        level: .timeSensitive, nowMs: Self.startedAt + 2000)
        #expect(noButton.categoryIdentifier == nil && noButton.interruptionLevel == .timeSensitive)
        expectValid(noButton, "call-notification.schema.json#/$defs/incoming")
    }

    @Test("Titles: the name, the number in national format, Unknown Caller without the call log, No Caller ID if hidden")
    func titles() {
        let byNumber = CallNotificationBuilder.incoming(Self.ringing(name: nil), pairId: Self.pairId, platform: .mobile,
                                                        level: .timeSensitive, nowMs: Self.startedAt)
        #expect(byNumber.title == "090 000 0123")
        let unknown = CallNotificationBuilder.incoming(Self.ringing(number: nil, name: nil, presentation: .unknown),
                                                       pairId: Self.pairId, platform: .mobile, level: .timeSensitive,
                                                       nowMs: Self.startedAt)
        #expect(unknown.title == L10n.Call.unknownCaller)
        let hidden = CallNotificationBuilder.incoming(Self.ringing(number: nil, name: nil, presentation: .restricted),
                                                      pairId: Self.pairId, platform: .mobile, level: .timeSensitive,
                                                      nowMs: Self.startedAt)
        #expect(hidden.title == L10n.Call.noCallerId)
        #expect(CallNames.incomingAnnouncement(.name("Nguyễn Văn A")) == L10n.A11y.callIncomingFrom(caller: "Nguyễn Văn A"))
    }

    @Test("Missed call: identifier, thread, body with time and SIM, Message only with a number and SMS (E10)")
    func missed() {
        let missed = MissedCall(pairId: Self.pairId, entryId: 5120, callId: Self.callId, number: "+84900000123",
                                caller: .name("Nguyễn Văn A"), ts: Self.startedAt, subId: 1, simLabel: "SIM 1")
        let content = CallNotificationBuilder.missed(missed, canMessage: true)
        #expect(content.identifier == "call-missed:\(Self.pairId):5120")
        #expect(content.threadIdentifier == "calls:\(Self.pairId)" && content.categoryIdentifier == "HL_CALL_MISSED")
        #expect(content.body == L10n.Call.missedBodySim(time: CallNames.time(Self.startedAt), simLabel: "SIM 1"))
        #expect(content.playsSound && content.interruptionLevel == nil)
        expectValid(content, "call-notification.schema.json#/$defs/missed")
        #expect(CallNotificationBuilder.missed(missed, canMessage: false).categoryIdentifier == nil)
        let flowA = MissedCall(pairId: Self.pairId, entryId: nil, callId: Self.callId, number: nil, caller: .unknownCaller,
                               ts: Self.startedAt, subId: nil, simLabel: nil)
        let flowAContent = CallNotificationBuilder.missed(flowA, canMessage: true)
        #expect(flowAContent.identifier == "call-missed:\(Self.pairId):\(Self.callId)")
        #expect(flowAContent.categoryIdentifier == nil && flowAContent.title == L10n.Call.unknownCaller)
        #expect(flowAContent.body == L10n.Call.missedBody(time: CallNames.time(Self.startedAt)))
        expectValid(flowAContent, "call-notification.schema.json#/$defs/missed")
        let pushed = CallNotificationBuilder.missed(missed, canMessage: true, pushed: true)
        #expect(pushed.identifier == nil && pushed.threadIdentifier == "calls")
        expectValid(pushed, "call-notification.schema.json#/$defs/missed")
    }

    @Test("Categories: Mac Answer and Decline; iPhone Decline only, destructive, after unlocking; Message with a field")
    func categories() throws {
        let mac = CallNotificationBuilder.macCategories()
        let incoming = try #require(mac.first { $0.identifier == "HL_CALL_INCOMING_MAC" })
        #expect(incoming.actions.map(\.identifier) == ["HL_CALL_ANSWER", "HL_CALL_REJECT"])
        #expect(incoming.actions.map(\.title) == [L10n.Call.answer, L10n.Call.decline])
        #expect(incoming.actions[1].options.contains(.destructive))
        #expect(incoming.hiddenPreviewsBodyPlaceholder == L10n.Call.incomingBody)
        let mobile = CallNotificationBuilder.mobileCategories()
        let decline = try #require(mobile.first { $0.identifier == "HL_CALL_INCOMING" }?.actions.first)
        #expect(decline.identifier == "HL_CALL_REJECT" && !decline.options.contains(.foreground))
        #expect(decline.options.contains(.destructive) && decline.options.contains(.authenticationRequired))
        let missed = try #require(mobile.first { $0.identifier == "HL_CALL_MISSED" })
        let message = try #require(missed.actions.first as? UNTextInputNotificationAction)
        #expect(message.identifier == "HL_CALL_SMS" && message.title == L10n.Call.message)
        #expect(message.textInputButtonTitle == L10n.Sms.send && missed.hiddenPreviewsBodyPlaceholder == L10n.Call.missedCall)
    }

    @Test("userInfo round trip and the responses to each action")
    func responses() {
        let incoming = CallNotificationInfo.incoming(pairId: Self.pairId, callId: Self.callId, startedAt: Self.startedAt)
        #expect(CallNotificationInfo(incoming.userInfo) == incoming)
        #expect(CallNotificationResponse(actionIdentifier: "HL_CALL_REJECT", userInfo: incoming.userInfo, userText: nil)
            == .reject(pairId: Self.pairId, callId: Self.callId, startedAt: Self.startedAt))
        #expect(CallNotificationResponse(actionIdentifier: "HL_CALL_ANSWER", userInfo: incoming.userInfo, userText: nil)
            == .answer(pairId: Self.pairId, callId: Self.callId))
        #expect(CallNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                         userInfo: incoming.userInfo, userText: nil)
            == .openIncoming(pairId: Self.pairId, callId: Self.callId))
        let missed = CallNotificationInfo.missed(pairId: Self.pairId, entryId: 5120, callId: nil, number: "+84900000123",
                                                 subId: 1)
        #expect(CallNotificationInfo(missed.userInfo) == missed)
        #expect(CallNotificationResponse(actionIdentifier: "HL_CALL_SMS", userInfo: missed.userInfo, userText: "Ok")
            == .message(pairId: Self.pairId, entryId: 5120, callId: nil, number: "+84900000123", subId: 1, text: "Ok"))
        #expect(CallNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                         userInfo: missed.userInfo, userText: nil)
            == .openMissed(pairId: Self.pairId, entryId: 5120, callId: nil))
        let sms: [AnyHashable: Any] = ["pair_id": Self.pairId, "thread_id": 42, "message_key": "sms:1"]
        #expect(CallNotificationInfo(sms) == nil)
    }
}
