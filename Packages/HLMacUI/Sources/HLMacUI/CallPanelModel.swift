import Foundation
import HLAppCore
import HLProtocol

/// What the call panel shows and the choices it offers; the app model fills it from the call controller.
@MainActor
public final class CallPanelModel: ObservableObject {
    @Published public internal(set) var call: ActiveCall?
    /// `call.quick_replies` for "Decline with Message…" (CALL-02 field 6).
    @Published public internal(set) var quickReplies: [String] = []
    /// "Decline with Message…" is offered: SMS is in effect and the phone can send (CALL-01 field 8).
    @Published public internal(set) var canReplyBySms = false
    /// The phone lacks `READ_CALL_LOG`: the hint of CALL-01 field 12.
    @Published public internal(set) var callerIdHint = false
    /// The phone's name, for "This feature is off on <phone>".
    @Published public internal(set) var phoneName = ""
    /// "Custom Message…" is being typed (CALL-02 field 7).
    @Published public var composing = false
    @Published public var customText = ""

    var answer: () -> Void = {}
    var decline: () -> Void = {}
    var reply: (String) -> Void = { _ in }
    var ignore: () -> Void = {}
    var end: () -> Void = {}

    public init() {}

    /// "Decline with Message…" is on the panel for this call (field 8).
    var offersReply: Bool {
        guard let call, call.phase == .ringing, call.state.controls.reject, call.state.number != nil else { return false }
        return canReplyBySms
    }

    /// The custom message is sent only when it is not empty after trimming whitespace (field 7).
    func sendCustom() {
        let text = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composing = false
        customText = ""
        reply(String(text.prefix(AppSettings.quickReplyMaxCharacters)))
    }
}
