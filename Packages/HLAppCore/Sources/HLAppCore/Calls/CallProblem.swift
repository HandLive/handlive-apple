import Foundation
import HLProtocol

/// Why a call command did not work, as the panel says it (CALL-02 field 10, CALL-03 field 12). The screens turn it
/// into the catalog text (`error.call_*`); this type carries no wording.
public enum CallProblem: Equatable, Sendable {
    /// `CALL_NOT_FOUND`, or a refusal while the phone is already idle: "The call has ended" (CALL-02 E1, CALL-03 E1).
    case callEnded
    /// `CALL_ACTION_NOT_ALLOWED`: "The call was answered on the phone" (CALL-02 E2).
    case answeredOnPhone
    /// `CALL_ACTION_NOT_ALLOWED` with `reason = system` on End: "End this call on the phone" (CALL-03 E9).
    case endOnPhone
    /// `PERMISSION_MISSING` (`ANSWER_PHONE_CALLS`): "The phone hasn't allowed HandLive to answer calls" (CALL-02 E3).
    case answerPermissionMissing
    /// `FEATURE_DISABLED`: "This feature is off on <phone>" (CALL-02 E4).
    case featureOffOnPhone
    /// No `ack` within `REQUEST_TIMEOUT` or no session: "Couldn't send the command to the phone" (CALL-02 E5).
    case commandNotSent
    /// Decline with Message after the call was answered: "The call was answered, so the message wasn't sent" (E9).
    case messageNotSent
    /// `CALL_HFP_REQUIRED` (never asked over WebSocket by this app): "Connect to the phone via Bluetooth…" (CALL-03 E2).
    case bluetoothRequired

    /// The problem an error `ack` of `call_event/action` names, for `command` (CALL-02 API 1 logic 6, CALL-03 API 1).
    public init(error: AckError, command: CallCommand) {
        switch error.code {
        case .callNotFound:
            self = .callEnded
        case .callActionNotAllowed:
            let details = error.details.flatMap { try? HLJSON.convert($0, to: CallActionNotAllowedDetails.self) }
            if details?.state == .idle {
                self = .callEnded
            } else if details?.reason == .system {
                self = command == .end ? .endOnPhone : .commandNotSent
            } else {
                self = command == .end ? .callEnded : .answeredOnPhone
            }
        case .permissionMissing: self = .answerPermissionMissing
        case .featureDisabled: self = .featureOffOnPhone
        case .callHfpRequired: self = .bluetoothRequired
        default: self = .commandNotSent
        }
    }

    /// The problem an error `ack` of `call_event/action` names for an app call (CALL-05): the call is not there
    /// (`CALL_NOT_FOUND`), the feature is off on the phone (`FEATURE_DISABLED`), anything else did not go through.
    /// `CALL_APP_ACTION_UNAVAILABLE` is not a problem line: the control is withdrawn until the next `app_call`.
    public init(appCallError error: AckError) {
        switch error.code {
        case .callNotFound: self = .callEnded
        case .featureDisabled: self = .featureOffOnPhone
        default: self = .commandNotSent
        }
    }
}
