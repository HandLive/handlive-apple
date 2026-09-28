import Foundation

/// Private-mode verdict for one reading, with the evidence the log keeps.
public enum PrivateVerdict: Equatable, Sendable {
    case normal
    case privateMode(marker: String)
    /// Nothing says either way (Safari without a probe result): the product must not send (W4 "unknown").
    case unknown

    public var logValue: String {
        switch self {
        case .normal: "false"
        case .privateMode: "true"
        case .unknown: "unknown"
        }
    }
}

/// What the browser reported for its front window: the three texts the script returns.
public struct PageReading: Equatable, Sendable {
    public let url: String
    public let title: String
    public let mode: String

    public init(url: String, title: String, mode: String) {
        self.url = url
        self.title = title
        self.mode = mode
    }

    /// Parses the script's list result; nil when it does not have three items.
    public init?(items: [String?]) {
        guard items.count == 3 else { return nil }
        self.init(url: items[0] ?? "", title: items[1] ?? "", mode: items[2] ?? "")
    }

    /// Safari's front window bounds from the third value ("left,top,right,bottom", top-left origin), or nil.
    public var safariBounds: WindowBounds? {
        let parts = mode.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return WindowBounds(left: parts[0], top: parts[1], right: parts[2], bottom: parts[3])
    }

    /// Private verdict from the scripting answer alone. Safari's answer never says; the caller adds its probe.
    public func verdict(family: ScriptingFamily, safariProbe: PrivateVerdict? = nil) -> PrivateVerdict {
        switch family {
        case .chromium:
            switch mode.lowercased() {
            case "normal": return .normal
            case "incognito": return .privateMode(marker: "mode:incognito")
            default: return .unknown
            }
        case .arc:
            return mode.lowercased() == "incognito" ? .privateMode(marker: "arc:incognito") : .unknown
        case .safari:
            return safariProbe ?? .unknown
        }
    }
}

/// A window rectangle in global screen points with a top-left origin, as AppleScript `bounds` and
/// `CGWindowListCopyWindowInfo` both report it.
public struct WindowBounds: Equatable, Sendable {
    public let left: Int, top: Int, right: Int, bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    /// From a CGWindow `kCGWindowBounds` rectangle (x, y, width, height).
    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.init(left: Int(originX.rounded()), top: Int(originY.rounded()), right: Int((originX + width).rounded()),
                  bottom: Int((originY + height).rounded()))
    }

    /// Same window within `tolerance` points on every edge (rounding differs between the two sources).
    public func matches(_ other: WindowBounds, tolerance: Int = 2) -> Bool {
        abs(left - other.left) <= tolerance && abs(top - other.top) <= tolerance &&
            abs(right - other.right) <= tolerance && abs(bottom - other.bottom) <= tolerance
    }
}
