import Foundation

/// The phone permissions SMS depends on, as the phone lists them in `permissions_missing` (0.7.2: the short Android
/// name; the full `android.permission.` name is accepted too).
public enum SmsPermissions {
    /// `READ_SMS`: without it nothing syncs (SMS-01 E2).
    public static let read = "READ_SMS"
    /// `SEND_SMS`: without it nothing is sent (SMS-04 E3).
    public static let send = "SEND_SMS"
    /// `READ_CONTACTS`: without it conversations show numbers instead of names (SMS-01 E3).
    public static let contacts = "READ_CONTACTS"

    /// Whether `permission` names `name`, in either form.
    public static func matches(_ permission: String, _ name: String) -> Bool {
        permission == name || permission == "android.permission." + name
    }

    /// A missing `READ_SMS` or `SEND_SMS`: selecting it shows the SMS instructions (SMS-01 field 7, PAIR-02 field 9).
    public static func isSms(_ permission: String) -> Bool {
        matches(permission, read) || matches(permission, send)
    }

    /// Any of `permissions` stops SMS from working fully: `READ_SMS` or `SEND_SMS` is missing.
    public static func smsMissing(in permissions: [String]) -> Bool {
        permissions.contains(where: isSms)
    }

    /// Names can't be shown (SMS-01 field 8).
    public static func contactsMissing(in permissions: [String]) -> Bool {
        permissions.contains { matches($0, contacts) }
    }
}
