#if os(iOS)
import HLAppCore
import HLDesignSystem
import HLLocalization
import SwiftUI
import UIKit

/// The pairing sheet (PairingCard, showing side; 02-ios-ipados.md Sheets): large detent, "Cancel" at the leading end,
/// the QR code the phone scans (no camera permission here), or a PIN; it closes itself once paired.
struct IOSPairingSheet: View {
    @StateObject private var controller: PairingController
    private let done: () -> Void

    init(model: IOSAppModel, done: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: PairingController(host: model, onPaired: { _ in done() }))
        self.done = done
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HLSpacing.space16) {
                    Text(controller.mode == .qr ? L10n.Pairing.qrInstructions : L10n.Pairing.pinInstructions)
                        .font(.body)
                        .multilineTextAlignment(.center)
                    code
                    Text(verbatim: controller.deviceName).font(.callout).foregroundStyle(Color.secondary)
                    Text(L10n.Pairing.qrCodeChangesIn(time: controller.countdownText))
                        .hlTextStyle(.timer)
                        .foregroundStyle(Color.secondary)
                    statusLine
                    if controller.mode == .qr {
                        Button(L10n.Pairing.usePin, action: controller.usePIN).hlButtonStyle(.plain)
                    }
                }
                .padding(HLSpacing.space24)
                .frame(maxWidth: .infinity)
            }
            .background(alignment: .top) {
                LinearGradient(colors: [HLColorToken.brandGlow.color, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 240)
                    .ignoresSafeArea()
            }
            .navigationTitle(L10n.Pairing.pairPhoneTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        controller.stop()
                        done()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    @ViewBuilder
    private var code: some View {
        switch controller.mode {
        case .qr:
            if controller.qrURI.isEmpty {
                ProgressView().frame(width: HLSize.qr, height: HLSize.qr) // the relay rendezvous is being joined
            } else {
                PairingQRCode(controller.qrURI)
            }
        case .pin:
            Text(verbatim: controller.pin.count == 6 ? "\(controller.pin.prefix(3)) \(controller.pin.suffix(3))" : controller.pin)
                .hlTextStyle(.codePin)
                .textSelection(.enabled)
                .accessibilityLabel(Text(verbatim: controller.pin.map(String.init).joined(separator: " ")))
        }
    }

    /// E3, E4, the local network guide and "Pairing…" while a scanned code is verified.
    @ViewBuilder
    private var statusLine: some View {
        if let notice = controller.notice {
            VStack(spacing: HLSpacing.space8) {
                Label(notice.iosText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(HLColorToken.textRed.color)
                    .multilineTextAlignment(.center)
                if notice == .localNetworkDenied {
                    Button(L10n.Common.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        } else if controller.progress == .verifying {
            HStack(spacing: HLSpacing.space8) {
                ProgressView()
                Text(L10n.Pairing.inProgress).font(.callout)
            }
        }
    }
}

extension PairingController.Notice {
    /// The iPhone and iPad wording of each notice (PAIR-01 E3, E4, field 10; SET-03 E1, E4).
    var iosText: String {
        switch self {
        case .insecure: L10n.Error.pairingAuthFailed
        case .phoneNotFound: L10n.Pairing.phoneNotFound
        case .localNetworkDenied: L10n.Setup.localNetworkDeniedIos
        case .saveFailed: L10n.Error.pairingFailed
        case .keysMissing: L10n.Setup.keysFailed
        }
    }
}
#endif
