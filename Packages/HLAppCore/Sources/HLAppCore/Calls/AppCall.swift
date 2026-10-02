import Foundation
import HLProtocol

/// A call of another app on the phone (Telegram, …) as this device shows it (CALL-05): the latest `call_event/app_call`
/// with the envelope that carried it, and what the user did here. It lives only while the call does: the caller's name
/// is never logged and never stored, and there is no app-call log.
public struct AppCall: Equatable, Sendable {
    public let pairId: String
    public internal(set) var data: AppCallData
    /// `ts` of the envelope that carried `data` (Android clock): orders versions and anchors the timer.
    public internal(set) var envelopeTs: Int64
    /// This device's clock when `data` arrived.
    public internal(set) var receivedAtMs: Int64
    /// "Ignore": no panel and no ringing here; the phone keeps ringing.
    public internal(set) var ignored = false
    /// A command waiting for its `ack` or for the next version: the buttons are locked.
    public internal(set) var command: CallCommand?
    /// Answer was accepted by the phone and the call has not moved on yet: with `answer_mode = tap` the user still has
    /// to tap the HandLive notification on the phone.
    public internal(set) var answerRequested = false
    /// Why the last command did not work, shown in the panel.
    public internal(set) var problem: CallProblem?
    /// The session to the phone is gone while the call goes on.
    public internal(set) var connectionLost = false
    /// Actions the phone refused as no longer offered (`CALL_APP_ACTION_UNAVAILABLE`), until its next `app_call`.
    var withdrawn: Set<CallAction> = []

    public var callId: String { data.callId }
    /// The app's label from the phone's package manager, for display (a proper name, not translated).
    public var appName: String { data.app.label }

    /// The panel to show: ringing → the incoming panel, ongoing → the in-call panel; ended calls are never shown.
    public var phase: CallPhase {
        switch data.state {
        case .ringing: .ringing
        case .ongoing: .inCall
        case .ended: .ended
        case .unrecognized: data.answeredAt == nil ? .ringing : .inCall
        }
    }

    /// The caller's name, or "Unknown Caller" when the notification gave none.
    public var caller: CallerIdentity {
        guard let name = data.caller, !name.isEmpty else { return .unknownCaller }
        return .name(name)
    }

    /// What the phone offers, less what it has refused since (answer → `answer`, decline → `reject`, end → `end`).
    public var controls: AppCallControls {
        AppCallControls(answer: data.controls.answer && !withdrawn.contains(.answer),
                        decline: data.controls.decline && !withdrawn.contains(.reject),
                        end: data.controls.end && !withdrawn.contains(.end))
    }

    /// Seconds of the timer at `nowMs`: `(envelope ts − answered_at)` plus the time since the envelope arrived here, so
    /// the two clocks never need to agree; from `started_at` when never answered (CALL-03 API 4 logic 1).
    public func elapsedSeconds(nowMs: Int64) -> Int {
        let start = data.answeredAt ?? data.startedAt
        return max(0, Int((envelopeTs - start + max(0, nowMs - receivedAtMs)) / 1000))
    }
}
