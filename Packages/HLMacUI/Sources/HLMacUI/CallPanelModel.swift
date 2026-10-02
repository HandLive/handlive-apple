import Foundation
import HLAppCore
import HLProtocol

/// What the call panel shows and the choices it offers; the app model fills it from the call controller.
@MainActor
public final class CallPanelModel: ObservableObject {
    @Published public internal(set) var call: ActiveCall?
    /// A call of another app on the phone (CALL-05): shown only while there is no cellular `call`; the panel has room
    /// for one call at a time.
    @Published public internal(set) var appCall: AppCall?
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

    /// The buttons of the cellular `call`: they act on that call only, never on an app call.
    var answer: () -> Void = {}
    var decline: () -> Void = {}
    var reply: (String) -> Void = { _ in }
    var ignore: () -> Void = {}
    var end: () -> Void = {}
    /// The buttons of an app call's panel (CALL-05), for the `call_id` that panel shows: they never reach the cellular
    /// call, and a call that is gone gets nothing.
    var appCommand: (_ command: CallCommand, _ callId: String) -> Void = { _, _ in }
    var appIgnore: (_ callId: String) -> Void = { _ in }

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
