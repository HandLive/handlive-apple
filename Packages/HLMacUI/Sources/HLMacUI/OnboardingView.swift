import HLAppCore
import HLDesignSystem
import HLLocalization
import HLTransport
import SwiftUI

/// Welcome window (Onboarding README, 2-patterns/01-thiet-lap-ban-dau.md): 520 × 560 pt, one step at a time,
/// one prominent button at the bottom right.
public struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow
    let close: () -> Void

    public init(model: AppModel, flow: OnboardingFlow, close: @escaping () -> Void) {
        self.model = model
        self.flow = flow
        self.close = close
    }

    public var body: some View {
        Group {
            if model.phase == .keysFailed {
                KeysFailedStep(model: model)
            } else {
                content
            }
        }
        .frame(width: 520, height: 560)
        .background(alignment: .top) {
            LinearGradient(colors: [HLColorToken.brandGlow.color, .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .welcome:
            WelcomeStep(flow: flow)
        case .applications:
            ApplicationsStep(flow: flow)
        case .notifications:
            PermissionPrimerView(title: L10n.Permission.notificationsPrimerTitleClient,
                                 message: L10n.Permission.notificationsPrimerClient, busy: flow.checking) {
                Task { await flow.requestNotifications() }
            }
        case .notificationsDenied:
            GuideStep(text: L10n.Setup.notificationsDeniedMac, pane: .notifications) { flow.afterNotificationsGuide() }
        case .localNetwork:
            PermissionPrimerView(title: L10n.Permission.localNetworkPrimerTitle,
                                 message: L10n.Infoplist.localNetworkUsage, busy: flow.checking) {
                Task { await flow.requestLocalNetwork() }
            }
        case .localNetworkDenied:
            GuideStep(text: L10n.Setup.localNetworkDeniedMac, pane: .localNetwork) { flow.afterLocalNetworkGuide() }
        case .pasteGuide:
            GuideStep(text: L10n.Settings.pastePermissionHint, pane: .privacyAndSecurity) { flow.afterPasteGuide() }
        case .pairing:
            PairingStep(model: model, flow: flow)
        case .paired(let name):
            PairedStep(name: name, close: close)
        }
    }
}

/// Step 1: "Welcome to HandLive" with the brand name in `brand-fire`, the privacy summary and the two choices.
struct WelcomeStep: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        OnboardingPage(primary: L10n.Common.getStarted, action: flow.start) {
            Text(Self.title).hlTextStyle(.brandLargeTitle).multilineTextAlignment(.center)
            Text(L10n.Setup.welcomeBodyClient).hlTextStyle(.macBody).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: HLSpacing.space8) {
                Toggle(L10n.Settings.openAtLogin, isOn: $flow.openAtLogin)
                Toggle(L10n.Settings.showInMenuBar, isOn: $flow.showInMenuBar)
                Text(L10n.Settings.showInMenuBarFooter).hlTextStyle(.macFootnote).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
        }
    }

    /// The localized title with the app name (a proper noun, never translated) colored.
    static var title: AttributedString {
        var title = AttributedString(L10n.Setup.welcomeTitle)
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "HandLive"
        if let range = title.range(of: name) { title[range].foregroundColor = HLColorToken.brandFire.color }
        return title
    }
}

/// Steps 4–5: offer to move into /Applications (virtual camera, C11); drag hint when that fails (E2).
struct ApplicationsStep: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        if flow.moveFailed {
            OnboardingPage(primary: L10n.Common.continue, action: flow.skipApplications) {
                Label(L10n.Setup.applicationsDragHint, systemImage: "folder").hlTextStyle(.macBody)
            }
        } else {
            OnboardingPage(primary: L10n.Setup.applicationsMove, action: flow.moveToApplications,
                           secondary: L10n.Setup.applicationsLater, secondaryAction: flow.skipApplications) {
                Label(L10n.Setup.applicationsPrompt, systemImage: "folder").hlTextStyle(.macBody)
            }
        }
    }
}

/// A guide to a page of System Settings (E3–E6), then "Continue".
struct GuideStep: View {
    let text: String
    let pane: SystemSettingsPane
    let next: () -> Void

    var body: some View {
        OnboardingPage(primary: L10n.Common.continue, action: next, secondary: L10n.Common.openSystemSettings,
                       secondaryAction: pane.open) {
            Label(text, systemImage: "info.circle").hlTextStyle(.macBody).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Step 7 of the welcome window: the pairing sheet opens over it at once; after Cancel the page offers
/// "Add Phone…" again (PAIR-01 step 1).
struct PairingStep: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow
    @State private var showingSheet = true

    var body: some View {
        OnboardingPage(primary: L10n.Pairing.addPhone, action: showSheet) {
            Image(systemName: "candybarphone").font(.system(size: 48)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.Pairing.emptyTitleClient).hlTextStyle(.brandTitle)
            Text(L10n.Pairing.emptyBodyClient).hlTextStyle(.macBody).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingSheet) {
            PairingSheet(model: model, onPaired: { name in
                showingSheet = false
                flow.paired(with: name)
            }, cancel: { showingSheet = false })
        }
    }

    private func showSheet() {
        showingSheet = true
    }
}

/// PAIR-01 step 12 in the first run: the phone's name and "Done".
struct PairedStep: View {
    let name: String
    let close: () -> Void

    var body: some View {
        OnboardingPage(primary: L10n.Common.done, action: close) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(HLColorToken.statusConnected.color)
                .accessibilityHidden(true)
            Text(L10n.Pairing.pairedWith(deviceName: name)).hlTextStyle(.brandTitle).multilineTextAlignment(.center)
        }
    }
}

/// SET-03 E1: the keys could not be created; "Try Again".
struct KeysFailedStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        OnboardingPage(primary: L10n.Common.retry, action: model.retryKeys) {
            Label(L10n.Setup.keysFailed, systemImage: "exclamationmark.triangle.fill").hlTextStyle(.macBody)
                .foregroundStyle(HLColorToken.textRed.color)
        }
    }
}
