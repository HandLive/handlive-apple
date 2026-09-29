import AppKit
import ApplicationServices
import WebSpikeCore

/// Safari's scripting dictionary has no private-window property, so the spike tries two probes and logs both:
///
/// 1. **Bounds:** the frontmost on-screen Safari window (`CGWindowListCopyWindowInfo`, no permission needed for
///    bounds) against the scripted `front window`. If they differ, the window in front is one scripting does not
///    see — which is what a private window hidden from Apple Events would look like.
/// 2. **Accessibility** (only when this process is trusted in Privacy & Security › Accessibility): the focused
///    window's elements outside the web content, looking for a description, title or identifier containing "private".
@MainActor
enum SafariPrivateProbe {
    struct Evidence {
        var boundsMatch: String = "n/a" // yes, no, n/a
        var axTrusted = false
        var axMarker: String?

        var verdict: PrivateVerdict {
            if let axMarker { return .privateMode(marker: "ax:\(axMarker)") }
            if boundsMatch == "no" { return .privateMode(marker: "script_front_mismatch") }
            return .unknown
        }
    }

    static func probe(pid: pid_t, scripted: WindowBounds?) -> Evidence {
        var evidence = Evidence()
        if let scripted, let front = frontWindowBounds(pid: pid) {
            evidence.boundsMatch = front.matches(scripted) ? "yes" : "no"
        }
        evidence.axTrusted = AXIsProcessTrusted()
        if evidence.axTrusted {
            evidence.axMarker = privateMarker(pid: pid)
        }
        return evidence
    }

    /// The first normal-layer, on-screen window of `pid` in front-to-back order.
    static func frontWindowBounds(pid: pid_t) -> WindowBounds? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double]
            else { continue }
            return WindowBounds(originX: bounds["X"] ?? 0, originY: bounds["Y"] ?? 0,
                                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        }
        return nil
    }

    private static func privateMarker(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = AXTree.attribute(app, kAXFocusedWindowAttribute) as AXUIElement? else { return nil }
        var marker: String?
        AXTree.walk(window, maxNodes: 400) { element, _ in
            for name in [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXHelpAttribute] {
                if let text = AXTree.attribute(element, name) as String?, text.lowercased().contains("private") {
                    let role = (AXTree.attribute(element, kAXRoleAttribute) as String?) ?? "?"
                    marker = "\(role)/\(name)"
                    return false
                }
            }
            return true
        }
        return marker
    }
}

/// Small helpers over the AX C API, shared by the probe and the `ax-dump` command.
enum AXTree {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Depth-first walk that does not enter web content (`AXWebArea`): only the browser's own chrome is read.
    static func walk(_ root: AXUIElement, maxNodes: Int, visit: (AXUIElement, Int) -> Bool) {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        while let (element, depth) = stack.popLast(), seen < maxNodes {
            seen += 1
            guard visit(element, depth) else { return }
            if (attribute(element, kAXRoleAttribute) as String?) == "AXWebArea" { continue }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
    }
}
