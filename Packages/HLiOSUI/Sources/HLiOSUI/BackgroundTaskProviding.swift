import Foundation
#if os(iOS)
import UIKit
#endif

/// A background task the system granted: the app keeps running after it leaves the foreground until it ends the task
/// or the system's time is up. `raw` is the system's identifier.
public struct BackgroundTaskToken: Hashable, Sendable {
    public let raw: Int

    public init(raw: Int) {
        self.raw = raw
    }
}

/// The system's background tasks (`UIApplication.beginBackgroundTask`) behind a seam, so the background grace of the
/// session (CONN-02 E3) runs in tests with a fake.
@MainActor
public protocol BackgroundTaskProviding: AnyObject {
    /// `nil` when the system refuses (`.invalid`). `expiration` runs on the main thread when the time is up; the task
    /// must be ended before it returns, or the system ends the app.
    func begin(name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken?
    func end(_ token: BackgroundTaskToken)
    /// The background time left; `nil` in the foreground or when the system does not say.
    var remaining: Duration? { get }
}

/// No background time at all: every request is refused, so the session closes as soon as the app leaves the
/// foreground. The default where there is no `UIApplication` (the package's tests on macOS).
@MainActor
public final class NoBackgroundTasks: BackgroundTaskProviding {
    public init() {}

    public func begin(name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? {
        nil
    }

    public func end(_ token: BackgroundTaskToken) {}

    public var remaining: Duration? { nil }
}

#if os(iOS)
/// `UIApplication.shared`'s background tasks.
@MainActor
public final class UIKitBackgroundTasks: BackgroundTaskProviding {
    public init() {}

    public func begin(name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expiration() } // UIKit calls the handler on the main thread
        }
        return identifier == .invalid ? nil : BackgroundTaskToken(raw: identifier.rawValue)
    }

    public func end(_ token: BackgroundTaskToken) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.raw))
    }

    /// `backgroundTimeRemaining` is `DBL_MAX` in the foreground: no limit known then.
    public var remaining: Duration? {
        let left = UIApplication.shared.backgroundTimeRemaining
        return left.isFinite && left < 3600 ? .seconds(left) : nil
    }
}
#endif
