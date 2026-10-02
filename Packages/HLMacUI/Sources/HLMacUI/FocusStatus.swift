import Foundation
import Intents
import Security

/// The Mac's Focus as calls see it (CALL-01 API 5 logic 3, E4).
public enum FocusState: String, Equatable, Sendable {
    /// No Focus is on: the panel shows and may ring.
    case off
    /// A Focus is on: no panel, no ringing; a time-sensitive notification lets the system decide.
    case on
    /// HandLive may not read the Focus status (not asked yet, or refused): the panel shows without ringing.
    case unknown
    /// This build cannot ask for the Focus status (no Communication Notifications capability), so the user has no way
    /// to allow it: calls alert as with Focus off, ringtone included.
    case unavailable
}

/// Reads the Focus status; tests use a stub.
@MainActor
public protocol FocusReading: AnyObject {
    var state: FocusState { get }
    /// HandLive may read the Focus status.
    var isAuthorized: Bool { get }
    /// This build can ask for the Focus status at all (it is signed with the Communication Notifications capability).
    var isAvailable: Bool { get }
    /// Asks the user once (when "Ring on Mac" is turned on); later calls only read the answer.
    func requestAuthorization() async -> Bool
}

/// `INFocusStatusCenter`: needs the Communication Notifications capability
/// (`com.apple.developer.usernotifications.communication`) and `NSFocusStatusUsageDescription`.
@MainActor
public final class SystemFocusStatus: FocusReading {
    public init() {}

    /// Read once from this process's code signature: a build signed without the capability (for example with a
    /// personal team) never appears in System Settings › Privacy & Security › Focus.
    public let isAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let entitlement = "com.apple.developer.usernotifications.communication" as CFString
        return (SecTaskCopyValueForEntitlement(task, entitlement, nil) as? Bool) == true
    }()

    public var isAuthorized: Bool {
        INFocusStatusCenter.default.authorizationStatus == .authorized
    }

    public var state: FocusState {
        guard isAvailable else { return .unavailable }
        guard isAuthorized, let focused = INFocusStatusCenter.default.focusStatus.isFocused else { return .unknown }
        return focused ? .on : .off
    }

    public func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        guard INFocusStatusCenter.default.authorizationStatus == .notDetermined else { return isAuthorized }
        return await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
