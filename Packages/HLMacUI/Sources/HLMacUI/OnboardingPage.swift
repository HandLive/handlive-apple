import HLDesignSystem
import HLLocalization
import SwiftUI

/// Layout of one first-run screen: content centered, buttons at the bottom right; the prominent button is the
/// default action (Return), a secondary button sits to its left.
struct OnboardingPage<Content: View>: View {
    let primary: String
    let action: () -> Void
    var secondary: String?
    var secondaryAction: (() -> Void)?
    var busy = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: HLSpacing.space20)
            VStack(spacing: HLSpacing.space20, content: content)
                .frame(maxWidth: 420)
            Spacer(minLength: HLSpacing.space20)
            HStack(spacing: HLSpacing.space12) {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if let secondary, let secondaryAction {
                    Button(secondary, action: secondaryAction)
                }
                Button(primary, action: action)
                    .hlButtonStyle(.prominent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(HLSpacing.space32)
    }
}

/// Explanation before a system permission prompt (PermissionPrimer): a title, one or two sentences, and exactly one
/// button, "Continue" — no Skip, no Cancel; the user answers in the system dialog (SET-03 field 14).
struct PermissionPrimerView: View {
    let title: String
    let message: String
    var busy = false
    let proceed: () -> Void

    var body: some View {
        OnboardingPage(primary: L10n.Common.continue, action: proceed, busy: busy) {
            Text(title).hlTextStyle(.brandTitle).multilineTextAlignment(.center)
            Text(message).hlTextStyle(.macBody).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Permission.primerFooter).hlTextStyle(.macFootnote).foregroundStyle(.secondary)
        }
    }
}
