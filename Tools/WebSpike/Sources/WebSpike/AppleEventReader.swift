import AppKit
import ApplicationServices
import WebSpikeCore

/// Sends the browser scripts (`BrowserTable.script(for:)`) with `NSAppleScript` and reads the Automation permission
/// without prompting (`AEDeterminePermissionToAutomateTarget`). Main thread only: NSAppleScript is not thread-safe.
@MainActor
final class AppleEventReader {
    enum Outcome {
        case reading(PageReading, milliseconds: Double)
        /// Script error: `-1743` not allowed (Automation denied, or hardened runtime without the entitlement),
        /// `-1712` timeout, `-600` not running, `-1728` no such object (no window), `-2753` unknown property.
        case failure(code: Int, milliseconds: Double)
    }

    private var compiled: [String: NSAppleScript] = [:]

    func read(_ spec: BrowserSpec) -> Outcome {
        let start = DispatchTime.now()
        let script = compiled[spec.bundleID] ?? {
            let made = NSAppleScript(source: BrowserTable.script(for: spec))!
            compiled[spec.bundleID] = made
            return made
        }()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        if let error {
            return .failure(code: (error[NSAppleScript.errorNumber] as? Int) ?? 0, milliseconds: elapsed)
        }
        let items = result.numberOfItems > 0
            ? (1...result.numberOfItems).map { result.atIndex($0)?.stringValue }
            : []
        guard let reading = PageReading(items: items) else { return .failure(code: -1, milliseconds: elapsed) }
        return .reading(reading, milliseconds: elapsed)
    }

    enum Permission: String {
        case granted, denied, notDetermined = "not_determined", notRunning = "not_running"
    }

    /// The Automation state for a browser, never showing the prompt. The browser must be running.
    static func permission(for bundleID: String, ask: Bool = false) -> (Permission, Int32) {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return (.notRunning, -600) }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return (.granted, status)
        case OSStatus(errAEEventNotPermitted): return (.denied, status)
        case OSStatus(errAEEventWouldRequireUserConsent): return (.notDetermined, status)
        default: return (.notRunning, status)
        }
    }
}
