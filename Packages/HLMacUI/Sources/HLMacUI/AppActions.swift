import Foundation

/// Actions that open windows or reach other modules; the app target wires them (window presenter, clipboard).
@MainActor
public struct AppActions {
    public var showPairing: () -> Void
    public var showOnboarding: () -> Void
    public var sendClipboard: () -> Void
    public var showMessages: () -> Void
    public var newMessage: () -> Void

    public init(showPairing: @escaping () -> Void, showOnboarding: @escaping () -> Void,
                sendClipboard: @escaping () -> Void, showMessages: @escaping () -> Void = {},
                newMessage: @escaping () -> Void = {}) {
        self.showPairing = showPairing
        self.showOnboarding = showOnboarding
        self.sendClipboard = sendClipboard
        self.showMessages = showMessages
        self.newMessage = newMessage
    }
}
