#if os(iOS)
import HLAppCore
import HLDesignSystem
import HLLocalization
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Clipboard tab (PasteCard, CLIP-04): the suggestion banner, the "Send to <phone>" card with the system Paste
/// button (no "Allow Paste" dialog), a conflict with "Send Again", and the last content received with "Copy".
struct ClipboardTabView: View {
    @ObservedObject var model: IOSAppModel
    let pair: () -> Void
    @State private var hud: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpacing.space16) {
                    if model.pairedDevice == nil {
                        NoPhoneView(pair: pair)
                    } else {
                        banner
                        sendCard
                        conflictCard
                        receivedCard
                    }
                }
                .padding(HLSpacing.space16)
            }
            .navigationTitle(L10n.Clipboard.title)
            .overlay(alignment: .top) { feedback }
        }
        .onReceive(model.$clipboardNotice) { notice in
            guard let notice, notice.isSuccess, let text = notice.iosText else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { hud = text }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { hud = nil }
            }
        }
    }

    /// Field 3: new content copied here; `{device_type}` is "iPhone" or "iPad" from `UIDevice.current.model`.
    @ViewBuilder
    private var banner: some View {
        if let text = model.unsentBannerText(deviceType: UIDevice.current.model, hasImages: UIPasteboard.general.hasImages) {
            HStack(alignment: .top, spacing: HLSpacing.space12) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.dismissUnsentBanner() } label: {
                    Image(systemName: "xmark").accessibilityLabel(Text(L10n.Common.done))
                }
                .buttonStyle(.borderless)
            }
            .padding(HLSpacing.space12)
            .background(RoundedRectangle(cornerRadius: HLRadius.card).fill(HLColorToken.secondarySystemBackground.color))
        }
    }

    /// Fields 1, 2, 4, 5, 7: the Paste button is enabled only with a session and clipboard sync on (E5).
    private var sendCard: some View {
        VStack(alignment: .leading, spacing: HLSpacing.space12) {
            Text(model.sendCardTitle ?? "").font(.headline)
            PasteButton(supportedContentTypes: pasteTypes) { providers in
                model.sendPasted(providers)
            }
            .buttonBorderShape(.capsule)
            .tint(Color.accentColor)
            .disabled(!model.connected || !model.clipboardEnabled)
            if let reason = model.clipboardUnavailableReason {
                Label(reason, systemImage: "info.circle").font(.footnote).foregroundStyle(HLColorToken.textOrange.color)
            } else {
                Text(model.connected ? L10n.Clipboard.pasteHint : L10n.Clipboard.notConnectedToPhone)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            if let notice = model.clipboardNotice, !notice.isSuccess, let text = notice.iosText {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(HLColorToken.textRed.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpacing.space16)
        .background(RoundedRectangle(cornerRadius: HLRadius.card).fill(HLColorToken.secondarySystemBackground.color))
    }

    /// E7: with "Sync Images" off the button accepts only text and links.
    private var pasteTypes: [UTType] {
        model.sendImages ? [.plainText, .url, .png, .jpeg, .image] : [.plainText, .url]
    }

    /// Fields 8–9: the phone kept its own newer content.
    @ViewBuilder
    private var conflictCard: some View {
        if let name = model.clipboardConflict {
            VStack(alignment: .leading, spacing: HLSpacing.space8) {
                Text(L10n.Clipboard.conflictTitle(deviceName: name)).font(.headline)
                Text(L10n.Clipboard.conflictBody).font(.subheadline).foregroundStyle(Color.secondary)
                HStack {
                    Button(L10n.Clipboard.sendAgain) { model.sendAgain() }.hlButtonStyle(.tinted)
                    Button(L10n.Common.cancel) { model.dismissConflict() }.hlButtonStyle(.plain)
                }
            }
            .padding(HLSpacing.space16)
            .background(RoundedRectangle(cornerRadius: HLRadius.card).fill(HLColorToken.secondarySystemBackground.color))
        }
    }

    /// Field 10: the last content received, or the empty state.
    @ViewBuilder
    private var receivedCard: some View {
        if let clip = model.received {
            VStack(alignment: .leading, spacing: HLSpacing.space8) {
                receivedContent(clip)
                Text(model.receivedCaption(clip)).font(.footnote).foregroundStyle(Color.secondary)
                Button { model.copyReceivedAgain() } label: {
                    Label(L10n.Clipboard.copy, systemImage: "doc.on.doc")
                }
                .hlButtonStyle(.tinted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HLSpacing.space16)
            .background(RoundedRectangle(cornerRadius: HLRadius.card).fill(HLColorToken.secondarySystemBackground.color))
        } else {
            VStack(spacing: HLSpacing.space8) {
                Image(systemName: "doc.on.clipboard").font(.largeTitle).foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
                Text(L10n.Clipboard.nothingReceived).font(.headline)
                Text(L10n.Clipboard.nothingReceivedBody).font(.subheadline).foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpacing.space24)
        }
    }

    @ViewBuilder
    private func receivedContent(_ clip: ReceivedClip) -> some View {
        if clip.sensitive {
            Label(L10n.Clipboard.sensitiveHidden, systemImage: "eye.slash").font(.body).foregroundStyle(Color.secondary)
        } else {
            switch clip.content {
            case .text(let text):
                Text(verbatim: text).font(.body).lineLimit(3)
            case .image(let image):
                if let picture = UIImage(data: image.data) {
                    Image(uiImage: picture).resizable().scaledToFit().frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.row))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// The `Feedback` HUD "Sent to <phone>".
    @ViewBuilder
    private var feedback: some View {
        if let hud {
            Label(hud, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, HLSpacing.space16)
                .padding(.vertical, HLSpacing.space12)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, HLSpacing.space8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// No phone yet (PAIR-02 empty state): the next step right in the tab.
struct NoPhoneView: View {
    let pair: () -> Void

    var body: some View {
        VStack(spacing: HLSpacing.space12) {
            Image(systemName: "candybarphone").font(.largeTitle).foregroundStyle(Color.secondary).accessibilityHidden(true)
            Text(L10n.Pairing.emptyTitleClient).hlTextStyle(.brandTitle)
            Text(L10n.Pairing.emptyBodyClient).font(.body).foregroundStyle(Color.secondary).multilineTextAlignment(.center)
            Button(L10n.Pairing.addPhone, action: pair).hlButtonStyle(.prominent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpacing.space40)
    }
}
#endif
