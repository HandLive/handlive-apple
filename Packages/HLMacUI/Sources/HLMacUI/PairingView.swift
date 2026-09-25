import HLDesignSystem
import HLLocalization
import HLTransport
import SwiftUI

/// The pairing sheet (`PairingCard`, showing side) over the welcome window or Settings: it owns the controller for
/// as long as it is shown; Cancel, Esc or closing the sheet drops the secret (PAIR-01 E5 on this side).
public struct PairingSheet: View {
    @StateObject private var controller: PairingController
    private let cancel: () -> Void

    public init(model: AppModel, onPaired: @escaping @MainActor (String) -> Void, cancel: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: PairingController(model: model, onPaired: onPaired))
        self.cancel = cancel
    }

    public var body: some View {
        PairingCardView(controller: controller) {
            controller.stop()
            cancel()
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }
}

/// Title, instructions, the QR code or the PIN, this Mac's name, the countdown, "Can't Scan? Use a PIN", the status
/// or error line, and "Cancel". A brand moment: `brand-glow` behind the content; the code itself never changes color.
struct PairingCardView: View {
    @ObservedObject var controller: PairingController
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: HLSpacing.space16) {
            Text(L10n.Pairing.pairPhoneTitle).hlTextStyle(.brandTitle)
            Text(controller.mode == .qr ? L10n.Pairing.qrInstructions : L10n.Pairing.pinInstructions)
                .hlTextStyle(.macBody)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            code
            Text(verbatim: controller.deviceName).hlTextStyle(.macCallout).foregroundStyle(.secondary)
            Text(L10n.Pairing.qrCodeChangesIn(time: controller.countdownText))
                .hlTextStyle(.timer)
                .foregroundStyle(.secondary)
            statusLine
                .frame(minHeight: 36)
            HStack {
                if controller.mode == .qr {
                    Button(L10n.Pairing.usePin, action: controller.usePIN).buttonStyle(.link)
                }
                Spacer()
                Button(L10n.Common.cancel, action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(HLSpacing.space24)
        .frame(width: 440)
        .background(alignment: .top) {
            LinearGradient(colors: [HLColorToken.brandGlow.color, .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var code: some View {
        switch controller.mode {
        case .qr:
            PairingQRCode(controller.qrURI)
        case .pin:
            Text(verbatim: Self.grouped(controller.pin))
                .hlTextStyle(.codePin)
                .textSelection(.enabled)
                .frame(height: HLSize.qr / 2)
                .accessibilityLabel(Text(verbatim: controller.pin.map(String.init).joined(separator: " ")))
        }
    }

    /// E3/E4 and the local network guide inside the sheet; "Pairing…" while a scanned QR code is verified.
    @ViewBuilder
    private var statusLine: some View {
        if let notice = controller.notice {
            VStack(spacing: HLSpacing.space8) {
                Label(notice.text, systemImage: "exclamationmark.triangle.fill")
                    .hlTextStyle(.macCallout)
                    .foregroundStyle(HLColorToken.textRed.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if notice == .localNetworkDenied {
                    Button(L10n.Common.openSystemSettings) { SystemSettingsPane.localNetwork.open() }
                }
            }
        } else if controller.mode == .qr, controller.progress == .verifying {
            HStack(spacing: HLSpacing.space8) {
                ProgressView().controlSize(.small)
                Text(L10n.Pairing.inProgress).hlTextStyle(.macCallout)
            }
        }
    }

    /// "482 915": two groups of three digits (`code-pin`).
    static func grouped(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return "\(pin.prefix(3)) \(pin.suffix(3))"
    }
}
