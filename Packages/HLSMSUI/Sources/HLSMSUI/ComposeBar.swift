import HLDesignSystem
import HLLocalization
import HLProtocol
import SwiftUI

/// The compose field of `MessageBubble/README.md` (SMS-04 fields 2–5): a capsule "SMS Message" field, the SIM chip on
/// dual-SIM phones, the round send button and the character and part counter under it. Return sends on the Mac.
public struct ComposeBar: View {
    @Binding var text: String
    @Binding var subId: Int32?
    let counter: String
    let sims: [SimInfo]
    let canSend: Bool
    let send: () -> Void

    public init(text: Binding<String>, subId: Binding<Int32?>, counter: String, sims: [SimInfo], canSend: Bool,
                send: @escaping () -> Void) {
        _text = text
        _subId = subId
        self.counter = counter
        self.sims = sims
        self.canSend = canSend
        self.send = send
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: HLSpacing.space4) {
            HStack(alignment: .bottom, spacing: HLSpacing.space8) {
                if !sims.isEmpty { simMenu }
                TextField(L10n.Sms.composePlaceholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .onSubmit { if canSend { send() } }
                    .padding(.horizontal, HLSpacing.space12)
                    .padding(.vertical, HLSpacing.space8)
                    .background(Capsule().strokeBorder(Color.hl(.separator)))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? Color.hl(.accentFill) : Color.hl(.tertiaryLabel))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(Text(L10n.Sms.send))
            }
            Text(counter).font(.caption2).foregroundStyle(Color.secondary).monospacedDigit()
        }
        .padding(HLSpacing.space12)
    }

    private var simMenu: some View {
        Menu {
            ForEach(sims, id: \.subId) { sim in
                Button {
                    subId = sim.subId
                } label: {
                    if sim.subId == subId { Label(sim.label, systemImage: "checkmark") } else { Text(sim.label) }
                }
            }
        } label: {
            Text(sims.first { $0.subId == subId }?.label ?? sims[0].label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, HLSpacing.space8)
                .padding(.vertical, HLSpacing.space4)
                .background(Capsule().fill(Color.hl(.tertiarySystemFill)))
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
    }
}
