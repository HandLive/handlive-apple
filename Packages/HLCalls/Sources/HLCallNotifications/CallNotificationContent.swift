import Foundation
import UserNotifications

/// One call notification as plain values (CALL-01 API 6–7, CALL-04 API 4): the apps and the extension turn it into a
/// `UNMutableNotificationContent`; the tests compare its JSON form with `call-notification.schema.json`.
public struct CallNotificationContent: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
        /// Notification Center only, no banner and no sound: the Mac while its panel shows the call.
        case passive
        case active
        /// A ringing call: breaks through Focus and the scheduled summary.
        case timeSensitive
    }

    /// The request identifier: the `call_id` of a Mac incoming call, `call-missed:…` of a missed call; `nil` when the
    /// system keeps its own (content an extension rebuilds).
    public var identifier: String?
    public var title: String
    public var body: String
    public var threadIdentifier: String
    /// `nil`: no actions (a late push, E7; a missed call without a number or SMS, E10).
    public var categoryIdentifier: String?
    /// `nil`: whatever the push (or the system default) gives.
    public var interruptionLevel: Level?
    public var playsSound: Bool
    public var info: CallNotificationInfo

    public init(identifier: String?, title: String, body: String, threadIdentifier: String, categoryIdentifier: String?,
                interruptionLevel: Level?, playsSound: Bool, info: CallNotificationInfo) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.interruptionLevel = interruptionLevel
        self.playsSound = playsSound
        self.info = info
    }

    /// The content with its `userInfo`, level and sound. The extension passes the push's own content as `base`, so what
    /// this content leaves open (the level of a late push) stays as the relay sent it, and the push's `p` and `hl` stay
    /// in `userInfo` next to the call's keys (the app reads them back to judge a notification it did not post).
    public func makeContent(base: UNNotificationContent? = nil) -> UNMutableNotificationContent {
        let content = (base?.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = threadIdentifier
        content.categoryIdentifier = categoryIdentifier ?? ""
        var userInfo = base?.userInfo ?? [:]
        for (key, value) in info.userInfo { userInfo[key] = value }
        content.userInfo = userInfo
        if playsSound { content.sound = .default }
        switch interruptionLevel {
        case .passive?: content.interruptionLevel = .passive
        case .active?: content.interruptionLevel = .active
        case .timeSensitive?: content.interruptionLevel = .timeSensitive
        case nil: break
        }
        return content
    }

    /// The JSON form of `call-notification.schema.json` (not a wire message: it pins what the platforms share).
    public var json: [String: Any] {
        var object: [String: Any] = ["title": title, "body": body, "threadIdentifier": threadIdentifier,
                                     "userInfo": info.json]
        if let identifier { object["identifier"] = identifier }
        if let categoryIdentifier { object["categoryIdentifier"] = categoryIdentifier }
        if let interruptionLevel { object["interruptionLevel"] = interruptionLevel.rawValue }
        // The schema pins the sound of missed calls only; a ringing call's sound comes from its push or its level.
        if playsSound, case .missed = info { object["sound"] = "default" }
        return object
    }
}
