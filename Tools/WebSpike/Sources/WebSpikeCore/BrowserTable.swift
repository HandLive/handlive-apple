/// How a browser answers Apple Events for its front window.
public enum ScriptingFamily: String, Sendable {
    /// Safari: `current tab of front window` (`URL`, `name`); no private-mode property in the dictionary, so the third
    /// value is the front window's `bounds` ("left,top,right,bottom"), compared with the frontmost on-screen window.
    case safari
    /// Chromium: `active tab of front window` (`URL`, `title`) and the window's `mode` ("normal" / "incognito").
    case chromium
    /// Arc: `active tab of front window` (`URL`, `title`); its private-window property is a spike question.
    case arc
}

/// A browser the spike watches (W4), with its W2 `browser` id.
public struct BrowserSpec: Equatable, Sendable {
    public let wireID: String
    public let bundleID: String
    public let family: ScriptingFamily
}

public enum BrowserTable {
    public static let all: [BrowserSpec] = [
        BrowserSpec(wireID: "safari", bundleID: "com.apple.Safari", family: .safari),
        BrowserSpec(wireID: "chrome", bundleID: "com.google.Chrome", family: .chromium),
        BrowserSpec(wireID: "edge", bundleID: "com.microsoft.edgemac", family: .chromium),
        BrowserSpec(wireID: "brave", bundleID: "com.brave.Browser", family: .chromium),
        BrowserSpec(wireID: "arc", bundleID: "company.thebrowser.Browser", family: .arc),
        BrowserSpec(wireID: "vivaldi", bundleID: "com.vivaldi.Vivaldi", family: .chromium),
        BrowserSpec(wireID: "opera", bundleID: "com.operasoftware.Opera", family: .chromium),
    ]

    /// The browser for a frontmost app's bundle id, or nil (Firefox: no URL scripting, unsupported by W4).
    public static func spec(forBundleID bundleID: String?) -> BrowserSpec? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleID == bundleID }
    }

    /// The AppleScript the spike sends to `spec`. Every value comes back as text, in the order url, title, and the
    /// private-mode value (Chromium `mode`, Arc marker, Safari window bounds). The timeout is short so a hung browser
    /// cannot stall the poll.
    public static func script(for spec: BrowserSpec) -> String {
        let body: String
        switch spec.family {
        case .safari:
            body = """
            set w to front window
            set t to current tab of w
            set b to bounds of w
            set bt to ((item 1 of b) as text) & "," & ((item 2 of b) as text) & "," & ¬
                ((item 3 of b) as text) & "," & ((item 4 of b) as text)
            return {URL of t as text, name of t as text, bt}
            """
        case .chromium:
            body = """
            set w to front window
            set t to active tab of w
            return {URL of t as text, title of t as text, mode of w as text}
            """
        case .arc:
            // Arc's dictionary is checked by the spike: `incognito` if it exists, else nothing.
            body = """
            set w to front window
            set t to active tab of w
            set m to ""
            try
                if incognito of w then set m to "incognito"
            end try
            return {URL of t as text, title of t as text, m}
            """
        }
        return """
        with timeout of 2 seconds
            tell application id "\(spec.bundleID)"
                if (count of windows) is 0 then return {"", "", ""}
        \(body.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n"))
            end tell
        end timeout
        """
    }
}
