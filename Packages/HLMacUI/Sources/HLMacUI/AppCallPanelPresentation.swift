import Foundation
import HLAppCore
import HLCallNotifications
import HLCallsUI
import HLLocalization

/// What the call panel shows for a call of another app (CALL-05): the lines and buttons that differ from a cellular call,
/// computed from the call alone so they can be tested without a view. The panel keeps the cellular call's look: Decline
/// on the left and Answer on the right while ringing, End while ongoing, Ignore under the buttons of a ringing call.
struct AppCallPanelPresentation: Equatable {
    /// "Telegram Call", ringing and ongoing alike (CALL-05 field 1).
    let title: String
    /// The caller's name, or "Unknown Caller".
    let callerTitle: String
    /// Buttons by what the phone offers (`controls`) in the state the call is in. Answer gives way to the tap hint.
    let showsAnswer: Bool
    let showsDecline: Bool
    let showsEnd: Bool
    /// "Ignore" closes the panel of a ringing call here and leaves it ringing on the phone.
    let showsIgnore: Bool
    /// A command waits for its `ack`: the buttons are locked.
    let isLocked: Bool
    /// "Answering…" or "Declining…" while a command waits.
    let progressText: String?
    /// "Tap the notification on your phone to answer.", replacing Answer once Answer went through with
    /// `answer_mode = tap`; Decline stays.
    let tapHint: String?
    /// "Audio: Phone" during the call: the audio of an app call stays on the phone.
    let audioNote: String?
    let connectionNote: String?
    let problemNote: String?
    /// What VoiceOver announces when the panel comes up for a ringing call: who calls, and the panel title.
    let announcement: String

    init(_ call: AppCall, phoneName: String) {
        let controls = call.controls
        let ringing = call.phase == .ringing
        let ongoing = call.phase == .inCall
        let waitingForTap = ringing && call.answerRequested && call.data.answerMode == .tap
        title = L10n.Call.appIncomingTitle(appName: call.appName)
        callerTitle = CallNames.title(call.caller)
        announcement = "\(CallNames.incomingAnnouncement(call.caller)), \(title)"
        showsAnswer = ringing && controls.answer && !waitingForTap
        showsDecline = ringing && controls.decline
        showsEnd = ongoing && controls.end
        showsIgnore = ringing
        isLocked = call.command != nil
        switch call.command {
        case .answer?: progressText = L10n.Call.answering
        case .reject?: progressText = L10n.Call.declining
        case .end?, nil: progressText = nil
        }
        tapHint = waitingForTap ? L10n.Call.appTapToAnswerHint : nil
        audioNote = ongoing ? L10n.Call.audioOnPhone : nil
        connectionNote = call.connectionLost ? L10n.Call.connectionLost : nil
        problemNote = call.problem.map { CallDisplay.problemText($0, phoneName: phoneName) }
    }
}
