import Foundation
import HLProtocol
import HLTransport

/// The phone as SMS reaches it: `sms/*` requests with their `ack`. The envelope `id` is chosen by the caller so a retry
/// of `sms/send` repeats the first `id` (SMS-04 step 5).
public protocol SmsPeer: Sendable {
    func request<Body: Encodable & Sendable>(_ op: SmsOp, data: Body, id: String, timeout: Duration) async throws -> Ack
    /// `lan` or `relay`: the `via` of the bench lines.
    var route: ConnectionRoute { get }
}

/// The current control session as the SMS peer.
public struct SessionSmsPeer: SmsPeer {
    let session: ControlSession

    public init(session: ControlSession) {
        self.session = session
    }

    public func request<Body: Encodable & Sendable>(_ op: SmsOp, data: Body, id: String,
                                                    timeout: Duration) async throws -> Ack {
        try await session.sendRequest(.sms, op: op.rawValue, data: data, id: id).response(timeout: timeout)
    }

    public var route: ConnectionRoute { session.route }
}

/// Status banner above the conversation list (SMS-01 field 1) with the count of the first sync (field 2).
public enum SmsSyncStatus: Equatable, Sendable {
    case idle
    /// `downloaded` counts the messages of this sync; `firstSync` shows "Downloaded 1,500 messages".
    case syncing(downloaded: Int, firstSync: Bool)
    case done
    case failed(SmsProblem)
}

/// Why SMS cannot work with the phone right now (SMS-01 E1, E2, E4, E6, E7; SMS-03 E2–E6).
public enum SmsProblem: Equatable, Sendable {
    /// SMS is off on this device or on the phone (E1).
    case featureOff
    /// The phone lacks `READ_SMS` (E2): show the SET-01 instructions.
    case permissionMissing
    /// Connection lost or no `ack` (E4): "Couldn't sync — will try again when connected".
    case interrupted
    /// The phone could not read its messages twice (E6).
    case phoneError
    /// The encrypted database could not be written (E7).
    case storage
}

/// State of loading older messages in one conversation (SMS-03 fields 10, 11).
public enum SmsHistoryState: Equatable, Sendable {
    case loading
    /// A page arrived; the phone has older messages still.
    case ready
    /// "Beginning of conversation".
    case complete
    /// E2: "Connect the phone to load older messages"; loads by itself after reconnecting.
    case needsConnection
    /// E3: "This conversation is no longer on the phone".
    case threadGone
    /// E4: error banner with "Try Again".
    case failed
    /// E5: SMS off or the permission missing on the phone.
    case unavailable(SmsProblem)
}

/// A received message that deserves a notification (SMS-02 step 7).
public struct SmsIncoming: Equatable, Sendable {
    public let pairId: String
    public let message: SmsMessageData
    public let thread: SmsThreadData
    /// The SIM label for the subtitle, only when the phone has more than one SIM (SMS-02 field 3).
    public let simLabel: String?
}

/// What the SMS engine tells the app (notifications, badge, banners); lists follow the database directly.
public enum SmsEvent: Equatable, Sendable {
    case syncStatus(SmsSyncStatus)
    case notify(SmsIncoming)
    /// Remove the conversation's notifications, those up to `upToTs` or all of them (SMS-05 API 2).
    case removeNotifications(pairId: String, threadId: Int64, upToTs: Int64?)
    /// After a completed sync: drop the generic notifications shown while the device was locked (SMS-05 API 2 logic 2).
    case removeGenericNotifications
    case badge(Int)
    case history(threadId: Int64, SmsHistoryState)
    /// No session while a message waits: ask the relay to wake the phone (CONN-04 `sms_send`).
    case needsPhone
}
