import AppKit
import HLAppCore
import HLCallNotifications
import HLDesignSystem
import HLTransport
import SwiftUI

/// What the call panel shows: the phone's cellular call, or a call of another app (CALL-05).
public enum CallPanelContent: Sendable {
    case cellular, app

    /// The bench line of the panel coming up (shared/tools/bench/README.md): `call_panel_shown` for a cellular call,
    /// `app_call_panel_shown` for a call of another app.
    var shownEvent: String {
        switch self {
        case .cellular: "call_panel_shown"
        case .app: "app_call_panel_shown"
        }
    }
}

/// Shows and hides the call panel; tests use a stub.
@MainActor
public protocol CallPanelPresenting: AnyObject {
    var isShown: Bool { get }
    /// Shows the panel (or keeps it) for the call `callId`, a cellular call or an app call (`content`); `announce`
    /// reads "Incoming call from …" with VoiceOver.
    func show(callId: String, content: CallPanelContent, announce: String?)
    func hide()
}

/// The panel that carries a floating window without taking focus: a non-activating `NSPanel` at the floating level on
/// every Space, full-screen apps included, that stays when HandLive is not active — a deliberate deviation from the HIG
/// (CALL-01 API 5, CallPanel README). It sits 16 pt from the top-right corner of the screen with the pointer, can be
/// dragged, and becomes key only when clicked, so Return, ⌘⌫ and Esc work once the user clicks it.
@MainActor
public final class CallPanelController: CallPanelPresenting {
    /// 340 pt wide (1-foundations/04-bo-cuc.md); the height fits the content.
    static let width: CGFloat = 340
    static let margin: CGFloat = 16

    private let model: CallPanelModel
    private var panel: CallPanelWindow?
    private var shownCallId: String?
    private var sizeObserver: NSObjectProtocol?
    /// The SwiftUI content, whose fitting size is the panel's height: the glass container reports none of its own.
    private var hosting: NSView?

    public init(model: CallPanelModel) {
        self.model = model
    }

    public var isShown: Bool { panel?.isVisible == true }

    public func show(callId: String, content: CallPanelContent, announce: String?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if shownCallId != callId || !panel.isVisible {
            shownCallId = callId
            place(panel)
            present(panel)
            BenchLog.event(content.shownEvent, ["call": callId])
            if let announce {
                NSAccessibility.post(element: panel, notification: .announcementRequested,
                                     userInfo: [.announcement: announce,
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        DispatchQueue.main.async { [weak self] in self?.fitHeight() } // after SwiftUI's first layout pass
    }

    public func hide() {
        shownCallId = nil
        panel?.orderOut(nil)
    }

    // MARK: - Window

    private func makePanel() -> CallPanelWindow {
        let panel = CallPanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
                                    styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                    backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: CallPanelView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hosting = hosting
        panel.contentView = Self.material(around: hosting)
        sizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                              object: hosting, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitHeight() }
        }
        hosting.postsFrameChangedNotifications = true
        return panel
    }

    /// Glass on macOS 26 (`NSGlassEffectView`), the `.popover` material before it (1-foundations/05-vat-lieu.md), with
    /// `radius-panel` corners.
    private static func material(around content: NSView) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = HLRadius.panel
            glass.contentView = content
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = HLRadius.panel
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// The top-right corner of the screen with the pointer (API 5 logic 1).
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let height = fittingHeight(panel)
        panel.setFrame(NSRect(x: visible.maxX - Self.width - Self.margin, y: visible.maxY - height - Self.margin,
                              width: Self.width, height: height), display: true)
    }

    /// The content changed (ringing → in call, a problem line): the top edge stays where it is.
    private func fitHeight() {
        guard let panel, panel.isVisible else { return }
        let height = fittingHeight(panel)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height), display: true)
    }

    private func fittingHeight(_ panel: NSPanel) -> CGFloat {
        max(80, hosting?.fittingSize.height ?? panel.contentView?.fittingSize.height ?? 160)
    }

    /// Slides in from the top-right corner and fades in, like a notification; only fades with Reduce Motion
    /// (1-foundations/07-chuyen-dong.md). `orderFrontRegardless()` shows it without activating HandLive.
    private func present(_ panel: NSPanel) {
        let target = panel.frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        if !reduceMotion { panel.setFrame(target.offsetBy(dx: 0, dy: 12), display: false) }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(target, display: true) }
        }
    }
}

/// The call panel's window: it may become key when clicked (keyboard shortcuts, the custom message field) but never
/// main, and never activates the app (`.nonactivatingPanel`).
final class CallPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
