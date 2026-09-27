#if os(iOS)
import HLAppCore
import HLCallNotifications
import HLCallsUI
import HLDesignSystem
import HLLocalization
import HLSMSNotifications
import SwiftUI

/// The in-app banner of a ringing call while the app is open (CALL-01 step 8, fields 1–5 and 7; CALL-02 fields 3,
/// 9–10): "Incoming Call" or "Call Waiting", the caller — only the waiting caller during a call waiting — the SIM label,
/// and "Decline" when the phone allows it. It closes when the call stops ringing; iPhone and iPad never answer (C7) and
/// never ring, the phone already does.
struct CallBannerView: View {
    @ObservedObject var calls: IOSCalls
    let phoneName: String

    var body: some View {
        VStack {
            if let call = calls.banner {
                content(call)
                    .padding(HLSpacing.space12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HLRadius.panel, style: .continuous))
                    .shadow(color: Color.black.opacity(0.18), radius: HLSpacing.space12, y: HLSpacing.space4)
                    .padding(.horizontal, HLSpacing.space8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: calls.banner?.callId)
    }

    private func content(_ call: ActiveCall) -> some View {
        let caller = call.waitingCaller ?? call.caller
        return VStack(alignment: .leading, spacing: HLSpacing.space8) {
            HStack(spacing: HLSpacing.space12) {
                CallerAvatar(caller: caller)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: HLSpacing.space8) {
                        Text(call.phase == .waiting ? L10n.Call.waitingTitle : L10n.Call.incomingTitle)
                        if let sim = call.state.simLabel, !sim.isEmpty { Text(verbatim: sim) }
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    Text(CallNames.title(caller)).font(.headline).lineLimit(2)
                    if case .name = caller, let number = call.state.waiting ? call.state.waitingNumber : call.state.number {
                        Text(PhoneNumberDisplay.format(number)).font(.subheadline).foregroundStyle(Color.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: HLSpacing.space8)
                if call.state.controls.reject, !call.state.waiting {
                    declineButton(locked: call.command != nil)
                }
            }
            notes(call)
        }
    }

    /// Field 7: the round red "Decline" (CALL-02 field 3), locked while the command waits (field 9).
    private func declineButton(locked: Bool) -> some View {
        Button(action: calls.decline) {
            Image(systemName: "phone.down.fill")
                .font(.title3)
                .foregroundStyle(Color.white)
                .frame(width: HLSize.hitIos, height: HLSize.hitIos)
                .background(Circle().fill(HLColorToken.callDeclineFill.color))
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.5 : 1)
        .accessibilityLabel(Text(L10n.Call.decline))
        .accessibilityHint(Text(L10n.Call.declineTooltip))
    }

    /// "Declining…", the connection lost, and why the last command did not work (CALL-02 fields 9–10).
    @ViewBuilder
    private func notes(_ call: ActiveCall) -> some View {
        if call.command != nil {
            Text(L10n.Call.declining).font(.footnote).foregroundStyle(Color.secondary)
        }
        if call.connectionLost {
            Text(L10n.Call.connectionLost).font(.footnote).foregroundStyle(HLColorToken.textOrange.color)
        }
        if let problem = call.problem {
            Text(CallDisplay.problemText(problem, phoneName: phoneName))
                .font(.footnote)
                .foregroundStyle(HLColorToken.textRed.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
