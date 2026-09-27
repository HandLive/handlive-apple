import Foundation
import HLProtocol
import HLTransport

/// The phone as calls reach it: `call_event/action` and `call_event/log_sync` with their `ack`. The envelope `id` is
/// chosen by the caller, so a command sent again after the session came back repeats its first `id` (CALL-02 step 4)
/// and the phone answers it from its de-duplication window (0.5.1 rule 2).
public protocol CallPeer: Sendable {
    func request<Body: Encodable & Sendable>(_ op: CallEventOp, data: Body, id: String,
                                             timeout: Duration) async throws -> Ack
    /// `lan` or `relay`: the `via` of the bench lines.
    var route: ConnectionRoute { get }
}

/// The current control session as the call peer.
public struct SessionCallPeer: CallPeer {
    let session: ControlSession

    public init(session: ControlSession) {
        self.session = session
    }

    public func request<Body: Encodable & Sendable>(_ op: CallEventOp, data: Body, id: String,
                                                    timeout: Duration) async throws -> Ack {
        try await session.sendRequest(.callEvent, op: op.rawValue, data: data, id: id).response(timeout: timeout)
    }

    public var route: ConnectionRoute { session.route }
}

/// The phone permissions calls depend on, as the phone lists them in `permissions_missing` (0.7.2: the short Android
/// name; the full `android.permission.` name is accepted too).
public enum CallPermissions {
    /// `READ_PHONE_STATE`: without it calls are not in effect at all (CALL-01 E1).
    public static let phoneState = "READ_PHONE_STATE"
    /// `READ_CALL_LOG`: the incoming number and the call log (CALL-01 E2, CALL-04 E2).
    public static let callLog = "READ_CALL_LOG"
    /// `READ_CONTACTS`: names instead of numbers.
    public static let contacts = "READ_CONTACTS"
    /// `ANSWER_PHONE_CALLS`: answer, decline and end (CALL-02 E3).
    public static let answer = "ANSWER_PHONE_CALLS"

    /// Whether `permission` names `name`, in either form.
    public static func matches(_ permission: String, _ name: String) -> Bool {
        permission == name || permission == "android.permission." + name
    }

    public static func missing(_ name: String, in permissions: [String]) -> Bool {
        permissions.contains { matches($0, name) }
    }
}
