import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLSMSNotifications

/// Callers and times as the call screens and notifications write them (CALL-01 fields 2–3, CALL-03 field 1, CALL-04
/// fields 2, 4, 8). Names are user content and never translated; the rest comes from the catalog.
public enum CallNames {
    /// The contact name, the number in national format, "No Caller ID", "Unknown Caller" or "Outgoing Call".
    public static func title(_ caller: CallerIdentity) -> String {
        switch caller {
        case .name(let name): name
        case .number(let number): PhoneNumberDisplay.format(number)
        case .noCallerId: L10n.Call.noCallerId
        case .unknownCaller: L10n.Call.unknownCaller
        case .outgoingCall: L10n.Call.outgoingCall
        }
    }

    /// "2:05 PM": the time of `ms` in the device's language (0.12.3).
    public static func time(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .omitted, time: .shortened)
    }

    /// VoiceOver when the panel or banner appears: "Incoming call from <name or number>" (CALL-01 special requirements).
    public static func incomingAnnouncement(_ caller: CallerIdentity) -> String {
        L10n.A11y.callIncomingFrom(caller: title(caller))
    }
}
