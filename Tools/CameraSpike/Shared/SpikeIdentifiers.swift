import os

/// Names shared by the spike's host app and Camera Extension. They differ from the product's
/// (`app.handlive.camera.device`, `08-camera-mic.md` 8.0) so the spike never collides with a later HandLive install.
enum SpikeIdentifiers {
    static let hostBundleID = "app.handlive.spike.camera"
    static let extensionBundleID = "app.handlive.spike.camera.extension"
    static let cameraName = "HandLive Camera Spike"
    static let cameraUID = "app.handlive.spike.camera.device"
    static let micInputUID = "app.handlive.spike.mic.input"
    static let micFeedUID = "app.handlive.spike.mic.feed"
    /// Darwin notifications posted by the extension when the source stream starts and stops (CAM-02 API 1).
    static let demandNotification = "app.handlive.spike.camera.demand"
    static let idleNotification = "app.handlive.spike.camera.idle"
    static let logSubsystem = "app.handlive.spike.camera"
}

extension Logger {
    /// `log stream --predicate 'subsystem == "app.handlive.spike.camera"'` shows both processes.
    static func spike(_ category: String) -> Logger {
        Logger(subsystem: SpikeIdentifiers.logSubsystem, category: category)
    }
}
