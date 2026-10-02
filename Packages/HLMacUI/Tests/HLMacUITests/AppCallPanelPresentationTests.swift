import Foundation
import HLCallsUI
import HLLocalization
import HLProtocol
import Testing
@testable import HLAppCore
@testable import HLMacUI

/// CALL-05 on the Mac panel: which buttons and lines an app call shows per state and per control the phone offers.
/// The panel reuses the cellular call's look; these are the lines that differ.
@Suite("App call panel: buttons, hint and notes per state")
@MainActor
struct AppCallPanelPresentationTests {
    func call(_ data: AppCallData, answerRequested: Bool = false, command: CallCommand? = nil,
              problem: CallProblem? = nil, connectionLost: Bool = false) -> AppCall {
        var call = AppCall(pairId: "pair", data: data, envelopeTs: 100, receivedAtMs: 100)
        call.answerRequested = answerRequested
        call.command = command
        call.problem = problem
        call.connectionLost = connectionLost
        return call
    }

    func presentation(_ call: AppCall, phone: String = "Pixel 8") -> AppCallPanelPresentation {
        AppCallPanelPresentation(call, phoneName: phone)
    }

    @Test("Ringing: the app's title, the caller, Decline and Answer from the controls, and Ignore")
    func ringing() {
        let shown = presentation(call(MacAppCallSamples.ringing()))
        #expect(shown.title == L10n.Call.appIncomingTitle(appName: "Telegram"))
        #expect(shown.callerTitle == "Nguyễn Văn A")
        #expect(shown.showsAnswer && shown.showsDecline && shown.showsIgnore && !shown.showsEnd)
        #expect(!shown.isLocked && shown.progressText == nil && shown.tapHint == nil && shown.audioNote == nil)
        #expect(shown.announcement == "\(L10n.A11y.callIncomingFrom(caller: "Nguyễn Văn A")), \(shown.title)")
    }

    @Test("Buttons follow what the phone offers: no answer intent hides Answer, no decline intent hides Decline")
    func buttonsFollowControls() {
        let noAnswer = presentation(call(MacAppCallSamples.ringing(controls: AppCallControls(decline: true))))
        #expect(!noAnswer.showsAnswer && noAnswer.showsDecline)
        let noDecline = presentation(call(MacAppCallSamples.ringing(controls: AppCallControls(answer: true))))
        #expect(noDecline.showsAnswer && !noDecline.showsDecline && noDecline.showsIgnore)
        let none = presentation(call(MacAppCallSamples.ringing(controls: .none)))
        #expect(!none.showsAnswer && !none.showsDecline && none.showsIgnore) // Ignore still closes the panel
    }

    @Test("A caller the notification did not name is Unknown Caller")
    func unknownCaller() {
        let shown = presentation(call(MacAppCallSamples.ringing(caller: nil)))
        #expect(shown.callerTitle == L10n.Call.unknownCaller)
    }

    @Test("Tap mode: after Answer the hint to tap the notification on the phone replaces Answer, and Decline stays")
    func tapHint() {
        let before = presentation(call(MacAppCallSamples.ringing(mode: .tap)))
        #expect(before.tapHint == nil && before.showsAnswer && before.showsDecline)
        let after = presentation(call(MacAppCallSamples.ringing(mode: .tap), answerRequested: true))
        #expect(after.tapHint == L10n.Call.appTapToAnswerHint)
        #expect(!after.showsAnswer && after.showsDecline && after.showsIgnore)
        let direct = presentation(call(MacAppCallSamples.ringing(mode: .direct), answerRequested: true))
        #expect(direct.tapHint == nil && direct.showsAnswer)
        let ongoing = presentation(call(MacAppCallSamples.ongoing(), answerRequested: true))
        #expect(ongoing.tapHint == nil)
    }

    @Test("A command in progress locks the buttons and says Answering… or Declining…")
    func locked() {
        let answering = presentation(call(MacAppCallSamples.ringing(), command: .answer(.phone)))
        #expect(answering.isLocked && answering.progressText == L10n.Call.answering)
        let declining = presentation(call(MacAppCallSamples.ringing(), command: .reject(reply: nil)))
        #expect(declining.isLocked && declining.progressText == L10n.Call.declining)
        let ending = presentation(call(MacAppCallSamples.ongoing(), command: .end))
        #expect(ending.isLocked && ending.showsEnd)
    }

    @Test("Ongoing: the app's title, End when the phone has an end action, the audio stays on the phone")
    func ongoing() {
        let shown = presentation(call(MacAppCallSamples.ongoing()))
        #expect(shown.title == L10n.Call.appIncomingTitle(appName: "Telegram"))
        #expect(shown.showsEnd && !shown.showsAnswer && !shown.showsDecline && !shown.showsIgnore)
        #expect(shown.audioNote == L10n.Call.audioOnPhone)
        let noEnd = presentation(call(MacAppCallSamples.ongoing(controls: .none)))
        #expect(!noEnd.showsEnd && noEnd.audioNote == L10n.Call.audioOnPhone)
    }

    @Test("Problems and a lost connection show as notes, in the words of the cellular call panel")
    func notes() {
        let ended = presentation(call(MacAppCallSamples.ongoing(), problem: .callEnded))
        #expect(ended.problemNote == L10n.Error.callNotFound)
        let off = presentation(call(MacAppCallSamples.ringing(), problem: .featureOffOnPhone), phone: "Pixel 8")
        #expect(off.problemNote == L10n.Error.featureDisabled(deviceName: "Pixel 8"))
        let notSent = presentation(call(MacAppCallSamples.ringing(), problem: .commandNotSent))
        #expect(notSent.problemNote == L10n.Error.callCommandNotSent)
        let lost = presentation(call(MacAppCallSamples.ongoing(), connectionLost: true))
        #expect(lost.connectionNote == L10n.Call.connectionLost && lost.problemNote == nil)
        #expect(presentation(call(MacAppCallSamples.ongoing())).connectionNote == nil)
    }
}
