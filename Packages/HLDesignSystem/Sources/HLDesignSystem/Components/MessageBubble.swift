import Foundation
import HLLocalization
import SwiftUI

/// One SMS in a conversation (`MessageBubble/README.md`, SMS-03 fields 6–9, SMS-04 fields 6–9): incoming messages on the
/// left in `bubble-incoming`, sent ones on the right in `bubble-outgoing`; links and phone numbers are detected; the
/// status of a message written here shows under the bubble, with "Try Again" when it failed.
public struct MessageBubble: View {
    public enum Status: Equatable, Sendable {
        case pending, sending, sent, delivered
        /// "Not sent · <reason>" with "Try Again".
        case failed(reason: String)
    }

    public struct Model: Equatable, Sendable {
        public var text: String
        public var isIncoming: Bool
        /// Status of a message written on this device; `nil` for the others.
        public var status: Status?
        /// Time and SIM under the last message of a cluster ("2:05 PM · SIM 2"); `nil` elsewhere.
        public var footnote: String?
        /// "{sender}, {time}" or "You, {time}, {status}" for VoiceOver; the text is the value (SMS-03 special requirements).
        public var accessibilityLabel: String

        public init(text: String, isIncoming: Bool, status: Status? = nil, footnote: String? = nil,
                    accessibilityLabel: String) {
            self.text = text
            self.isIncoming = isIncoming
            self.status = status
            self.footnote = footnote
            self.accessibilityLabel = accessibilityLabel
        }
    }

    private let model: Model
    private let onRetry: (() -> Void)?

    public init(_ model: Model, onRetry: (() -> Void)? = nil) {
        self.model = model
        self.onRetry = onRetry
    }

    #if os(macOS)
    private let captionStyle = HLTextStyle.macCaption2
    private let bodyStyle = HLTextStyle.macBody
    #else
    private let captionStyle = HLTextStyle.iosCaption1
    private let bodyStyle = HLTextStyle.iosBody
    #endif

    public var body: some View {
        VStack(alignment: model.isIncoming ? .leading : .trailing, spacing: 2) {
            HStack(alignment: .bottom, spacing: HLSpacing.space4) {
                if !model.isIncoming { Spacer(minLength: HLSpacing.space40) }
                if case .failed = model.status {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.hl(.systemRed))
                }
                Text(Self.linked(model.text))
                    .hlTextStyle(bodyStyle)
                    .foregroundStyle(model.isIncoming ? Color.hl(.label) : Color.hl(.onBubbleOutgoing))
                    .tint(model.isIncoming ? Color.hl(.label) : Color.hl(.onBubbleOutgoing))
                    .textSelection(.enabled)
                    .padding(.horizontal, HLSpacing.space12)
                    .padding(.vertical, HLSpacing.space8)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(model.isIncoming ? Color.hl(.bubbleIncoming) : Color.hl(.bubbleOutgoing)))
                if model.isIncoming { Spacer(minLength: HLSpacing.space40) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.accessibilityLabel))
            .accessibilityValue(Text(model.text))
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let status = model.status {
            HStack(spacing: HLSpacing.space4) {
                statusView(status)
                if case .failed = status, let onRetry {
                    Button(L10n.Common.retry, action: onRetry).buttonStyle(.borderless)
                }
            }
            .hlTextStyle(captionStyle)
            .foregroundStyle(Color.secondary)
        } else if let footnote = model.footnote {
            Text(footnote).hlTextStyle(captionStyle).foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private func statusView(_ status: Status) -> some View {
        switch status {
        case .pending: Label(L10n.Sms.statusPending, systemImage: "clock")
        case .sending:
            HStack(spacing: HLSpacing.space4) {
                ProgressView().controlSize(.mini)
                Text(L10n.Sms.statusSending)
            }
        case .sent: Label(L10n.Sms.statusSent, systemImage: "checkmark")
        case .delivered: Label(L10n.Sms.statusDelivered, systemImage: "checkmark.circle")
        case .failed(let reason): Text(L10n.Sms.statusFailedReason(reason: reason)).foregroundStyle(Color.hl(.destructiveText))
        }
    }

    /// Links and phone numbers underlined and tappable, in the color of the text.
    nonisolated static func linked(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return attributed }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: attributed)
            else { continue }
            let url = match.url ?? match.phoneNumber.flatMap { URL(string: "tel:" + $0.filter { !$0.isWhitespace }) }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }
}
