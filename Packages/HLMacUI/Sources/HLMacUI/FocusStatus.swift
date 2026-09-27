import Foundation
import Intents

/// The Mac's Focus as calls see it (CALL-01 API 5 logic 3, E4).
public enum FocusState: String, Equatable, Sendable {
    /// No Focus is on: the panel shows and may ring.
    case off
    /// A Focus is on: no panel, no ringing; a time-sensitive notification lets the system decide.
    case on
    /// HandLive may not read the Focus status (not asked yet, or refused): the panel shows without ringing.
    case unknown
}

/// Reads the Focus status; tests use a stub.
@MainActor
public protocol FocusReading: AnyObject {
    var state: FocusState { get }
    /// HandLive may read the Focus status.
    var isAuthorized: Bool { get }
    /// Asks the user once (when "Ring on Mac" is turned on); later calls only read the answer.
    func requestAuthorization() async -> Bool
}

/// `INFocusStatusCenter` (entitlement `com.apple.developer.focus-status`, `NSFocusStatusUsageDescription`).
@MainActor
public final class SystemFocusStatus: FocusReading {
    public init() {}

    public var isAuthorized: Bool {
        INFocusStatusCenter.default.authorizationStatus == .authorized
    }

    public var state: FocusState {
        guard isAuthorized, let focused = INFocusStatusCenter.default.focusStatus.isFocused else { return .unknown }
        return focused ? .on : .off
    }

    public func requestAuthorization() async -> Bool {
        guard INFocusStatusCenter.default.authorizationStatus == .notDetermined else { return isAuthorized }
        return await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
