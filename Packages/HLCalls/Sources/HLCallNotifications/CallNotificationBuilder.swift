import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLSMSNotifications
import Intents
import UserNotifications

/// Call notifications for the Mac, the iPhone/iPad app and the Notification Service Extension: the same titles, bodies,
/// threads, categories and `userInfo` everywhere (CALL-01 API 6–7, CALL-04 API 4).
public enum CallNotificationBuilder {
    /// Where the notification shows: the Mac answers and declines, iPhone and iPad only decline (C7).
    public enum Platform: Sendable {
        case mac, mobile
    }

    /// CALL-01 E7: a push this much older than `started_at` shows "Incoming call at <time>" without a button.
    public static let latePushMs: Int64 = 60_000

    /// The incoming call (field 11 on iPhone/iPad, field 15 on the Mac): the caller as the title, "Incoming call" (with
    /// the SIM label when the phone has two SIMs) as the body. The buttons follow `controls` (field 7), so none of them
    /// ever does nothing: iPhone and iPad get "Decline" when the phone allows it, the Mac "Answer" and "Decline" only
    /// when it allows both. A late push on iPhone/iPad has no button and keeps the level the relay gave it (E7).
    public static func incoming(_ state: CallStateData, pairId: String, platform: Platform,
                                level: CallNotificationContent.Level, nowMs: Int64) -> CallNotificationContent {
        let late = platform == .mobile && nowMs - state.startedAt > latePushMs
        let body: String
        if late {
            body = L10n.Call.incomingLate(time: CallNames.time(state.startedAt))
        } else if let sim = state.simLabel, !sim.isEmpty {
            body = L10n.Call.incomingBodySim(simLabel: sim)
        } else {
            body = L10n.Call.incomingBody
        }
        let category = category(state.controls, platform: platform)
        return CallNotificationContent(
            identifier: platform == .mac ? state.callId : nil, title: CallNames.title(CallerIdentity(state: state)),
            body: body, threadIdentifier: CallNotificationKeys.threadIdentifier,
            categoryIdentifier: late ? nil : category, interruptionLevel: late ? nil : level,
            playsSound: platform == .mac && level == .timeSensitive,
            info: .incoming(pairId: pairId, callId: state.callId, startedAt: state.startedAt))
    }

    /// The category whose actions `controls` all allow, or none.
    static func category(_ controls: CallControls, platform: Platform) -> String? {
        switch platform {
        case .mac: controls.answer && controls.reject ? CallNotificationKeys.incomingMacCategory : nil
        case .mobile: controls.reject ? CallNotificationKeys.incomingCategory : nil
        }
    }

    /// A missed call (CALL-04 field 8): the caller, "Missed call · 2:05 PM" (with the SIM label), and "Message" only
    /// when there is a number and the phone can send SMS (E10). `pushed`: content the extension rebuilds keeps the
    /// system's identifier and the relay's thread.
    public static func missed(_ missed: MissedCall, canMessage: Bool, pushed: Bool = false) -> CallNotificationContent {
        let time = CallNames.time(missed.ts)
        let body = missed.simLabel.map { L10n.Call.missedBodySim(time: time, simLabel: $0) }
            ?? L10n.Call.missedBody(time: time)
        return CallNotificationContent(
            identifier: pushed ? nil : CallNotificationKeys.missedIdentifier(pairId: missed.pairId, entryId: missed.entryId,
                                                                             callId: missed.callId),
            title: CallNames.title(missed.caller), body: body,
            threadIdentifier: pushed ? CallNotificationKeys.threadIdentifier
                : CallNotificationKeys.missedThreadIdentifier(pairId: missed.pairId),
            categoryIdentifier: missed.number != nil && canMessage ? CallNotificationKeys.missedCategory : nil,
            interruptionLevel: nil, playsSound: true,
            info: .missed(pairId: missed.pairId, entryId: missed.entryId, callId: missed.callId, number: missed.number,
                          subId: missed.subId))
    }

    /// The communication form of an incoming call (`INStartCallIntent`): the caller's name and avatar, and Focus
    /// filtering by the number (CALL-01 API 6–7). Falls back to the plain content when the system refuses the intent
    /// (no Communication Notifications capability).
    public static func communication(_ content: UNMutableNotificationContent, state: CallStateData) -> UNNotificationContent {
        let caller = CallerIdentity(state: state)
        var name: String?
        if case .name(let displayName) = caller { name = displayName }
        let avatar = InitialsAvatar.pngData(for: name).map { INImage(imageData: $0) }
        let handle = state.number.map { INPersonHandle(value: $0, type: .phoneNumber) }
            ?? INPersonHandle(value: nil, type: .unknown)
        let person = INPerson(personHandle: handle, nameComponents: nil, displayName: CallNames.title(caller),
                              image: avatar, contactIdentifier: nil, customIdentifier: state.number)
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                                       destinationType: .normal, contacts: [person], callCapability: .audioCall)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return (try? content.updating(from: intent)) ?? content
    }

    /// The Mac's categories: `HL_CALL_INCOMING_MAC` with "Answer" and "Decline" (set only when the phone allows both),
    /// `HL_CALL_MISSED` with "Message".
    public static func macCategories() -> Set<UNNotificationCategory> {
        let incoming = UNNotificationCategory(
            identifier: CallNotificationKeys.incomingMacCategory,
            actions: [answerAction(), declineAction(options: [.destructive])], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: L10n.Call.incomingBody, options: [])
        return [incoming, missedCategory()]
    }

    /// iPhone and iPad: `HL_CALL_INCOMING` with "Decline" only — destructive and only once the device is unlocked, so
    /// the app can read `PRK` (CALL-02 API 6 logic 1) — and `HL_CALL_MISSED` with "Message".
    public static func mobileCategories() -> Set<UNNotificationCategory> {
        let incoming = UNNotificationCategory(
            identifier: CallNotificationKeys.incomingCategory,
            actions: [declineAction(options: [.destructive, .authenticationRequired])], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: L10n.Call.incomingBody, options: [])
        return [incoming, missedCategory()]
    }

    private static func answerAction() -> UNNotificationAction {
        UNNotificationAction(identifier: CallNotificationKeys.answerAction, title: L10n.Call.answer, options: [],
                             icon: UNNotificationActionIcon(systemImageName: "phone.fill"))
    }

    private static func declineAction(options: UNNotificationActionOptions) -> UNNotificationAction {
        UNNotificationAction(identifier: CallNotificationKeys.rejectAction, title: L10n.Call.decline, options: options,
                             icon: UNNotificationActionIcon(systemImageName: "phone.down.fill"))
    }

    private static func missedCategory() -> UNNotificationCategory {
        let message = UNTextInputNotificationAction(
            identifier: CallNotificationKeys.messageAction, title: L10n.Call.message, options: [],
            icon: UNNotificationActionIcon(systemImageName: "message"), textInputButtonTitle: L10n.Sms.send,
            textInputPlaceholder: L10n.Sms.composePlaceholder)
        return UNNotificationCategory(identifier: CallNotificationKeys.missedCategory, actions: [message],
                                      intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: L10n.Call.missedCall,
                                      options: [])
    }
}
