import AppKit
import HLAppCore
import HLCallNotifications
import HLCallsUI
import HLDesignSystem
import HLLocalization
import HLProtocol
import HLSMSNotifications
import SwiftUI

/// The `CallPanel` component (CALL-01 fields 1–10, CALL-02 fields 5–10, CALL-03 fields 1–5 and 12): ringing, call
/// waiting, in call and ended. Decline sits on the left and Answer on the right in every state; Return answers, ⌘⌫
/// declines, Esc ignores. Mute, Hold and Keypad need Bluetooth (Phase 4), so their place shows the reason.
struct CallPanelView: View {
    @ObservedObject var model: CallPanelModel

    var body: some View {
        if let call = model.call {
            VStack(alignment: .leading, spacing: HLSpacing.space12) {
                header(call)
                details(call)
                controls(call)
            }
            .padding(HLSpacing.space16)
            .frame(width: CallPanelController.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Caller

    private func header(_ call: ActiveCall) -> some View {
        HStack(alignment: .top, spacing: HLSpacing.space12) {
            CallerAvatar(caller: call.caller)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HLSpacing.space8) {
                    Text(Self.title(call)).hlTextStyle(.macFootnote).foregroundStyle(Color.secondary)
                    if let sim = call.state.simLabel, !sim.isEmpty {
                        Text(sim)
                            .hlTextStyle(.macFootnote)
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, HLSpacing.space4)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.5)))
                    }
                }
                Text(CallNames.title(call.caller))
                    .hlTextStyle(.macHeadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if case .name = call.caller, let number = call.state.number {
                    Text(PhoneNumberDisplay.format(number)).hlTextStyle(.macSubheadline).foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Field 1: "Incoming Call"; in a call, the status and the timer: "On call", or "Call waiting" while a second call
    /// rings — the Mac keeps the in-call panel for it (CALL-01 field 1, CALL-03 field 3; "Call Waiting" is the
    /// iPhone/iPad banner's title); "Call ended · 02:05".
    static func title(_ call: ActiveCall) -> String {
        switch call.phase {
        case .ringing: L10n.Call.incomingTitle
        case .waiting: L10n.Call.statusWaiting
        case .inCall: L10n.Call.statusOnCall
        case .ended: L10n.Call.statusEnded(duration: CallDisplay.timer(call.elapsedSeconds(nowMs: 0)))
        }
    }

    // MARK: - Lines under the caller

    @ViewBuilder
    private func details(_ call: ActiveCall) -> some View {
        if call.phase == .inCall || call.phase == .waiting {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Text(CallDisplay.timer(call.elapsedSeconds(nowMs: Int64(Date().timeIntervalSince1970 * 1000))))
                        .monospacedDigit()
                    Spacer()
                    Text(call.state.audioOn == .mac ? L10n.Call.audioOnMac : L10n.Call.audioOnPhone)
                        .foregroundStyle(Color.secondary)
                }
                .hlTextStyle(.macSubheadline)
            }
        }
        if let waiting = call.waitingCaller {
            VStack(alignment: .leading, spacing: 2) {
                Text(CallNames.title(waiting)).hlTextStyle(.macSubheadline)
                if !call.state.hfpConnected {
                    Text(L10n.Call.waitingHandleOnPhone).hlTextStyle(.macFootnote).foregroundStyle(Color.secondary)
                }
            }
        }
        if model.callerIdHint, call.phase == .ringing, call.state.number == nil {
            note(L10n.Call.callerIdPermissionHint, color: .hl(.textOrange))
        }
        if call.phase == .inCall, !call.state.hfpConnected {
            note(L10n.Error.callHfpRequired, color: .secondary)
        }
        if call.connectionLost {
            note(L10n.Call.connectionLost, color: .hl(.textOrange))
        }
        if let problem = call.problem {
            note(CallDisplay.problemText(problem, phoneName: model.phoneName), color: .hl(.textRed))
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
    private func controls(_ call: ActiveCall) -> some View {
        switch call.phase {
        case .ringing:
            ringingControls(call)
        case .inCall, .waiting:
            if Self.offersEnd(call) {
                HStack {
                    Spacer()
                    CallRoundButton(title: L10n.Call.end, symbol: "phone.down.fill", fill: .callDeclineFill,
                                    tooltip: L10n.Call.endTooltip, action: model.end)
                        .disabled(call.command != nil)
                }
            }
        case .ended:
            EmptyView()
        }
    }

    /// "End" in a call; none while a call waits, where `controls.end` is `false` and the waiting call is handled on the
    /// phone or over Bluetooth (CALL-03 E7).
    static func offersEnd(_ call: ActiveCall) -> Bool {
        call.state.controls.end && !call.state.waiting
    }

    @ViewBuilder
    private func ringingControls(_ call: ActiveCall) -> some View {
        let locked = call.command != nil
        if let command = call.command {
            Text(command == .answer(.phone) || command == .answer(.mac) ? L10n.Call.answering : L10n.Call.declining)
                .hlTextStyle(.macFootnote)
                .foregroundStyle(Color.secondary)
        }
        HStack {
            if call.state.controls.reject {
                CallRoundButton(title: L10n.Call.decline, symbol: "phone.down.fill", fill: .callDeclineFill,
                                tooltip: L10n.Call.declineTooltip, action: model.decline)
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            Spacer()
            if call.state.controls.answer {
                CallRoundButton(title: L10n.Call.answer, symbol: "phone.fill", fill: .callAcceptFill,
                                tooltip: L10n.Call.answerTooltip, action: model.answer)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(locked)
        if model.composing {
            customMessage
        } else {
            HStack {
                if model.offersReply {
                    Menu(L10n.Call.declineWithMessageEllipsis) {
                        ForEach(model.quickReplies, id: \.self) { reply in
                            Button(reply) { model.reply(reply) }
                        }
                        Divider()
                        Button(L10n.Call.customMessageEllipsis) { model.composing = true }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(locked)
                }
                Spacer()
                Button(L10n.Call.ignore, action: model.ignore)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    /// "Custom Message…": one line and "Send"; nothing goes out while it is empty (CALL-02 field 7).
    private var customMessage: some View {
        HStack {
            TextField(L10n.Sms.composePlaceholder, text: Binding(
                get: { model.customText },
                set: { model.customText = String($0.prefix(AppSettings.quickReplyMaxCharacters)) }))
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.sendCustom)
            Button(L10n.Common.cancel) { model.composing = false }
                .keyboardShortcut(.cancelAction)
            Button(L10n.Sms.send, action: model.sendCustom)
                .keyboardShortcut(.defaultAction)
                .disabled(model.customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
