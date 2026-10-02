import HLAppCore
import HLCallsUI
import HLDesignSystem
import HLLocalization
import SwiftUI

/// The `CallPanel` for a call of another app (CALL-05): the cellular call panel's look with the app's name in the title.
/// Ringing shows Decline, Answer (or the tap hint) and Ignore as the phone's controls allow; ongoing shows the timer, that
/// the audio stays on the phone, and End. Return answers, ⌘⌫ declines, Esc ignores, as for a cellular call. Everything
/// it says comes from `AppCallPanelPresentation`. The panel closes when the call ends: there is no "Call ended" state.
/// Its buttons name the call's `call_id`, so they act on this app call only.
struct AppCallPanelView: View {
    @ObservedObject var model: CallPanelModel
    let call: AppCall

    private var shown: AppCallPanelPresentation {
        AppCallPanelPresentation(call, phoneName: model.phoneName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpacing.space12) {
            header
            details
            controls
        }
        .padding(HLSpacing.space16)
        .frame(width: CallPanelController.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Caller

    private var header: some View {
        HStack(alignment: .top, spacing: HLSpacing.space12) {
            CallerAvatar(caller: call.caller)
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.title).hlTextStyle(.macFootnote).foregroundStyle(Color.secondary)
                Text(shown.callerTitle)
                    .hlTextStyle(.macHeadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Lines under the caller

    @ViewBuilder
    private var details: some View {
        if call.phase == .inCall {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Text(CallDisplay.timer(call.elapsedSeconds(nowMs: Int64(Date().timeIntervalSince1970 * 1000))))
                        .monospacedDigit()
                    Spacer()
                    if let audio = shown.audioNote {
                        Text(audio).foregroundStyle(Color.secondary)
                    }
                }
                .hlTextStyle(.macSubheadline)
            }
        }
        if let hint = shown.tapHint {
            note(hint, color: .secondary)
        }
        if let lost = shown.connectionNote {
            note(lost, color: .hl(.textOrange))
        }
        if let problem = shown.problemNote {
            note(problem, color: .hl(.textRed))
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .hlTextStyle(.macFootnote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var controls: some View {
        switch call.phase {
        case .ringing, .waiting:
            ringingControls
        case .inCall:
            if shown.showsEnd {
                HStack {
                    Spacer()
                    CallRoundButton(title: L10n.Call.end, symbol: "phone.down.fill", fill: .callDeclineFill,
                                    tooltip: L10n.Call.endTooltip) { model.appCommand(.end, call.callId) }
                        .disabled(shown.isLocked)
                }
            }
        case .ended:
            EmptyView()
        }
    }

    @ViewBuilder
    private var ringingControls: some View {
        if let progress = shown.progressText {
            Text(progress).hlTextStyle(.macFootnote).foregroundStyle(Color.secondary)
        }
        HStack {
            if shown.showsDecline {
                CallRoundButton(title: L10n.Call.decline, symbol: "phone.down.fill", fill: .callDeclineFill,
                                tooltip: L10n.Call.declineTooltip) { model.appCommand(.reject(reply: nil), call.callId) }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            Spacer()
            if shown.showsAnswer {
                CallRoundButton(title: L10n.Call.answer, symbol: "phone.fill", fill: .callAcceptFill,
                                tooltip: L10n.Call.answerTooltip) { model.appCommand(.answer(.phone), call.callId) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(shown.isLocked)
        if shown.showsIgnore {
            HStack {
                Spacer()
                Button(L10n.Call.ignore) { model.appIgnore(call.callId) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
