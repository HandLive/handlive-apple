import HLDesignSystem
import HLLocalization
import HLSMS
import SwiftUI

/// "New Message" (SMS-04 fields 1–5): the "To:" number field, the messages sent from here waiting for the phone's
/// copy, and the compose field; the conversation replaces this screen once the phone reports it (step 11).
public struct NewMessageView: View {
    @ObservedObject var model: NewMessageModel
    @FocusState private var recipientFocused: Bool

    public init(model: NewMessageModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            recipientField
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HLSpacing.space4) {
                    ForEach(model.sent) { entry in
                        let status = SmsDisplay.bubbleStatus(entry.state, error: entry.errorCode)
                        MessageBubble(MessageBubble.Model(
                            text: entry.body, isIncoming: false, status: status,
                            accessibilityLabel: SmsDisplay.placeholderAccessibility(entry, status: status)))
                    }
                }
                .padding(.horizontal, HLSpacing.space12)
                .padding(.vertical, HLSpacing.space8)
            }
            ComposeBar(text: $model.draft, subId: $model.subId, counter: model.counter, sims: model.sims,
                       canSend: model.canSend) { Task { await model.send() } }
        }
        .navigationTitle(L10n.Sms.newMessage)
        .onAppear { recipientFocused = true }
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: HLSpacing.space4) {
            HStack(spacing: HLSpacing.space8) {
                Text(L10n.Sms.recipientLabel).foregroundStyle(Color.secondary).accessibilityHidden(true)
                TextField(text: $model.recipient, prompt: nil) { Text(L10n.Sms.recipientLabel) }
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($recipientFocused)
                    #if os(iOS)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    #endif
            }
            if model.recipientInvalid {
                Text(L10n.Error.smsInvalidAddress).font(.footnote).foregroundStyle(Color.hl(.statusError))
            }
        }
        .padding(HLSpacing.space12)
    }
}
