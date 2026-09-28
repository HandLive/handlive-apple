import AppKit
import ApplicationServices
import WebSpikeCore

/// `ax-dump`: writes the accessibility tree of the frontmost browser's focused window, outside the web content, so
/// Safari's private-window markers can be found. Values are redacted to their length; a `private_hint` is kept when
/// a description, title or identifier contains "private". Needs Privacy & Security › Accessibility for the terminal
/// (or the app bundle).
@MainActor
enum AXDump {
    static func run(out: String?, log: EventLog) {
        guard AXIsProcessTrusted() else {
            log.write(["ev": "ax_dump", "reason": "not_trusted"])
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let browser = BrowserTable.spec(forBundleID: app.bundleIdentifier)
        else {
            log.write(["ev": "ax_dump", "reason": "no_browser_in_front"])
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = AXTree.attribute(element, kAXFocusedWindowAttribute) as AXUIElement? else {
            log.write(["ev": "ax_dump", "browser": browser.wireID, "reason": "no_focused_window"])
            return
        }
        let version = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] }
        var lines = ["# browser=\(browser.wireID) version=\(version ?? "?")",
                     "# os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "# values are redacted to their length; web content (AXWebArea) is not entered"]
        var count = 0
        AXTree.walk(window, maxNodes: 2_000) { node, depth in
            count += 1
            lines.append(String(repeating: "  ", count: depth) + describe(node))
            return true
        }
        let path = out ?? "ax-\(browser.wireID)-\(Int(Date().timeIntervalSince1970)).txt"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        log.write(["ev": "ax_dump", "browser": browser.wireID, "nodes": count, "file": path])
    }

    private static func describe(_ node: AXUIElement) -> String {
        var parts = [(AXTree.attribute(node, kAXRoleAttribute) as String?) ?? "?"]
        if let subrole = AXTree.attribute(node, kAXSubroleAttribute) as String? { parts.append("sub=\(subrole)") }
        if let identifier = AXTree.attribute(node, kAXIdentifierAttribute) as String? { parts.append("id=\(identifier)") }
        for (label, name) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute)] {
            guard let text = AXTree.attribute(node, name) as String?, !text.isEmpty else { continue }
            parts.append("\(label)_len=\(text.count)")
            if text.lowercased().contains("private") { parts.append("private_hint=\(label)") }
        }
        if let value = AXTree.attribute(node, kAXValueAttribute) as String?, !value.isEmpty {
            parts.append("value_len=\(value.count)")
            if URLNormalizer.normalize(value) != nil { parts.append("url") }
        }
        return parts.joined(separator: " ")
    }
}
