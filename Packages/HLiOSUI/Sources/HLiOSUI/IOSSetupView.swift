#if os(iOS)
import HLAppCore
import HLDesignSystem
import HLLocalization
import SwiftUI
import UIKit

/// First run on iPhone and iPad (SET-03, Onboarding and PermissionPrimer READMEs): one screen at a time, the text in
/// a scroll view so it never truncates at the largest text sizes, and one prominent button at the bottom.
struct IOSSetupView: View {
    @StateObject private var flow: IOSSetupFlow

    init(model: IOSAppModel, registerForPush: @escaping @MainActor () -> Void) {
        _flow = StateObject(wrappedValue: IOSSetupFlow(model: model, registerForPush: registerForPush))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpacing.space16) {
                page
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(HLSpacing.space24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: HLSpacing.space8) {
                primaryButton
                    .hlButtonStyle(.prominent)
                    .disabled(flow.checking)
                if flow.step == .notifications || flow.step == .localNetwork {
                    Text(L10n.Permission.primerFooter).font(.footnote).foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(HLSpacing.space16)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch flow.step {
        case .welcome:
            Image(systemName: "iphone.and.arrow.forward").font(.system(size: 48)).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(L10n.Setup.welcomeTitle).hlTextStyle(.brandLargeTitle)
            Text(L10n.Setup.welcomeBodyClient).font(.body)
            if let privacy = PrivacyPage.url() {
                Link(L10n.Setup.welcomePrivacyLink, destination: privacy)
            }
        case .notifications:
            primer(symbol: "bell.badge", title: L10n.Permission.notificationsPrimerTitleClient,
                   body: L10n.Permission.notificationsPrimerClient)
        case .notificationsDenied:
            guide(L10n.Setup.notificationsDeniedIos)
        case .localNetwork:
            primer(symbol: "wifi", title: L10n.Permission.localNetworkPrimerTitle, body: L10n.Permission.localNetworkPrimer)
        case .localNetworkDenied:
            guide(L10n.Setup.localNetworkDeniedIos)
        case .limits:
            primer(symbol: "iphone", title: L10n.Setup.iosLimitsTitle, body: L10n.Setup.iosLimits) // SET-03 field 11
        }
    }

    private func primer(symbol: String, title: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpacing.space16) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            if let title { Text(title).font(.title2.bold()) }
            Text(body).font(.body)
        }
    }

    /// E3, E4: what is off and the way back, with "Open Settings".
    private func guide(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpacing.space16) {
            Label(text, systemImage: "info.circle").font(.body).foregroundStyle(HLColorToken.textOrange.color)
            Button(L10n.Common.openSettings) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .hlButtonStyle(.tinted)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch flow.step {
        case .welcome:
            Button { flow.start() } label: { Text(L10n.Common.getStarted).frame(maxWidth: .infinity) }
        case .notifications:
            Button { Task { await flow.continueFromNotifications() } } label: { continueLabel }
        case .notificationsDenied:
            Button { flow.afterNotificationsGuide() } label: { continueLabel }
        case .localNetwork:
            Button { Task { await flow.continueFromLocalNetwork() } } label: { continueLabel }
        case .localNetworkDenied:
            Button { flow.afterLocalNetworkGuide() } label: { continueLabel }
        case .limits:
            Button { flow.finish() } label: { continueLabel }
        }
    }

    private var continueLabel: some View {
        HStack(spacing: HLSpacing.space8) {
            if flow.checking { ProgressView() }
            Text(L10n.Common.continue)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
