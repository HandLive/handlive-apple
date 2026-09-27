import Foundation
import HLAppCore
import HLCallNotifications
import HLLocalization
import HLProtocol
@preconcurrency import UserNotifications

/// Opens a call push the extension could not (it came while the device was locked): the ringing state inside, read
/// with the pair's `K_push` while the app runs unlocked; `nil` for anything else.
public typealias CallPushReader = @Sendable ([AnyHashable: Any]) -> CallStateData?

/// Call notifications of iPhone and iPad (CALL-01 API 6 logic 4, CALL-02 field 11, CALL-04 API 4): the extension shows
/// the pushed ones; the app removes those whose call moved on, posts missed calls while it runs, and says when an
/// action from a notification did not reach the phone. Tests use a stub.
@MainActor
public protocol IOSCallNotifying: AnyObject {
    /// The incoming-call notifications of `callId`: its `state` is no longer `ringing`.
    func removeIncoming(callId: String, reader: @escaping CallPushReader)
    /// Every incoming-call notification whose call started more than 60 s ago (the app enters the foreground).
    func removeStaleIncoming(nowMs: Int64, reader: @escaping CallPushReader)
    func postMissed(_ missed: MissedCall, canMessage: Bool)
    /// A pair's missed-call notifications: one entry's, or all of them, generic ones included (CALL-04 step 12).
    func removeMissed(pairId: String, entryId: Int64?)
    /// Every call notification (unpairing, calls turned off here).
    func removeAllCalls()
    /// "Couldn't decline the call. It's still ringing on the phone." (CALL-02 E8).
    func postDeclineFailed(callId: String)
    /// "Not sent yet. Open HandLive to try again." after "Message" on a missed call (CALL-04 API 4, SMS-04 API 5).
    func postReplyNotSent(pairId: String, key: String)
}

#if os(iOS)
/// `UNUserNotificationCenter` for calls on iPhone and iPad.
@MainActor
public final class UserNotificationCallsIOS: IOSCallNotifying {
    public init() {}

    public func removeIncoming(callId: String, reader: @escaping CallPushReader) {
        CallNotificationCenter.removeDelivered {
            CallNotificationFilter.incomingIdentifiers(in: $0, callId: callId, decode: reader)
        }
    }

    public func removeStaleIncoming(nowMs: Int64, reader: @escaping CallPushReader) {
        CallNotificationCenter.removeDelivered {
            CallNotificationFilter.staleIncomingIdentifiers(in: $0, nowMs: nowMs, decode: reader)
        }
    }

    public func postMissed(_ missed: MissedCall, canMessage: Bool) {
        CallNotificationCenter.postMissed(missed, canMessage: canMessage)
    }

    public func removeMissed(pairId: String, entryId: Int64?) {
        CallNotificationCenter.removeDelivered {
            CallNotificationFilter.missedIdentifiers(in: $0, pairId: pairId, entryId: entryId)
        }
    }

    public func removeAllCalls() {
        CallNotificationCenter.removeDelivered { CallNotificationFilter.callIdentifiers(in: $0) }
    }

    public func postDeclineFailed(callId: String) {
        post(identifier: "call-decline-failed:\(callId)", body: L10n.Call.declineFailed)
    }

    public func postReplyNotSent(pairId: String, key: String) {
        post(identifier: "call-sms-not-sent:\(pairId):\(key)", body: L10n.Sms.quickReplyNotSent)
    }

    /// A plain notice in the calls thread, with the default sound.
    private func post(identifier: String, body: String) {
        let content = UNMutableNotificationContent()
        content.body = body
        content.threadIdentifier = CallNotificationKeys.threadIdentifier
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content,
                                                                     trigger: nil))
    }
}
#endif
