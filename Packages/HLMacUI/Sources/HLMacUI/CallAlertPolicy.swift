import Foundation
import HLAppCore
import HLCallNotifications

/// How the Mac alerts the call the phone reports (CALL-01 step 7, E3, E4, API 5 and 7; CALL-03 step 1): one visible
/// layer per call — the panel, or the notification banner while a Focus hides the panel.
public struct CallAlert: Equatable, Sendable {
    /// The floating panel (ringing, call waiting, in call, "Call ended").
    public var panel: Bool
    /// The Mac's own ringtone.
    public var ring: Bool
    /// The communication notification of a ringing call; `nil`: none (or remove it).
    public var notification: CallNotificationContent.Level?

    public static let none = CallAlert(panel: false, ring: false, notification: nil)

    /// - Parameters:
    ///   - notify: `call.notify` (field 13); off → only the menu bar menu (E3).
    ///   - ringtone: `call.ringtone` (field 14).
    ///   - focus: the Focus status: on → no panel, no ringing, a time-sensitive notification (E4); not readable → the
    ///     panel without ringing and a passive notification, as with Focus off.
    ///   - answeredHere: the call was answered from this Mac (its notification during a Focus): the in-call panel
    ///     opens anyway (CALL-01 API 7 "Response").
    public static func of(_ call: ActiveCall?, notify: Bool, ringtone: Bool, focus: FocusState,
                          answeredHere: Bool = false) -> CallAlert {
        guard let call, notify else { return .none }
        switch call.phase {
        case .ringing:
            if focus == .on { return CallAlert(panel: false, ring: false, notification: .timeSensitive) }
            let ring = ringtone && focus == .off && !call.ignored
            return CallAlert(panel: !call.ignored, ring: ring, notification: .passive)
        case .waiting, .inCall, .ended:
            // The in-call panel follows the call; a Focus keeps it away unless the call was answered here.
            return CallAlert(panel: (focus != .on || answeredHere) && !call.ignored, ring: false, notification: nil)
        }
    }

    /// The `level` of the `call_alert` bench line.
    var benchLevel: String {
        switch notification {
        case .passive?: "passive"
        case .timeSensitive?: "time_sensitive"
        case .active?, nil: "none"
        }
    }
}
