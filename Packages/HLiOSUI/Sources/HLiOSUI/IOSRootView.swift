#if os(iOS)
import HLDesignSystem
import HLLocalization
import SwiftUI

/// The app's root (02-ios-ipados.md): setup (SET-03) until `setup.completed_at`, then the tab bar — Clipboard,
/// Messages with the unread badge, Settings. The pairing sheet opens by itself once while no phone is paired
/// (PAIR-01 step 1); the tabs never hide, they explain the next step in their content.
public struct IOSRootView: View {
    @ObservedObject var model: IOSAppModel
    private let registerForPush: @MainActor () -> Void
    @State private var pairing = false
    @State private var offeredPairing = false

    public init(model: IOSAppModel, registerForPush: @escaping @MainActor () -> Void) {
        self.model = model
        self.registerForPush = registerForPush
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .launching: ProgressView()
            case .keysFailed: KeysFailedView(model: model)
            case .ready:
                if model.setupCompleted {
                    tabs
                } else {
                    IOSSetupView(model: model, registerForPush: registerForPush)
                }
            }
        }
        .sheet(isPresented: $pairing) {
            IOSPairingSheet(model: model) { pairing = false }
        }
    }

    private var tabs: some View {
        TabView(selection: $model.selectedTab) {
            ClipboardTabView(model: model) { pairing = true }
                .tabItem { Label(L10n.Clipboard.title, systemImage: "doc.on.clipboard.fill") }
                .tag(IOSTab.clipboard)
            MessagesTabView(model: model)
                .tabItem { Label(L10n.Sms.title, systemImage: "message.fill") }
                .badge(model.unreadThreads)
                .tag(IOSTab.messages)
            SettingsTabView(model: model) { pairing = true }
                .tabItem { Label(L10n.Settings.title, systemImage: "gearshape.fill") }
                .tag(IOSTab.settings)
        }
        .onAppear {
            guard model.pairedDevice == nil, !offeredPairing else { return }
            offeredPairing = true
            pairing = true
        }
    }
}

/// SET-03 E1: the keys could not be created; nothing works until they are.
struct KeysFailedView: View {
    @ObservedObject var model: IOSAppModel

    var body: some View {
        VStack(spacing: HLSpacing.space16) {
            Image(systemName: "key.slash").font(.largeTitle).foregroundStyle(Color.secondary).accessibilityHidden(true)
            Text(L10n.Setup.keysFailed).font(.body).multilineTextAlignment(.center)
            Button(L10n.Common.retry) { model.retryKeys() }.hlButtonStyle(.prominent)
        }
        .padding(HLSpacing.space24)
    }
}
#endif
