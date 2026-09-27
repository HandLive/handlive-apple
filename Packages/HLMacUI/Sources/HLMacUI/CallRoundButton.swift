import HLDesignSystem
import SwiftUI

/// A round call button (48 pt, `size-call-button`) with its name under it: solid `call-accept-fill` or
/// `call-decline-fill` with a white symbol; the colors never follow the accent color (CallPanel README).
struct CallRoundButton: View {
    let title: String
    let symbol: String
    let fill: HLColorToken
    /// "Answer the call", "Decline the call", "End the call" (CALL-01 fields 6–7, CALL-03 field 5).
    let tooltip: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: HLSpacing.space4) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.hl(.onCallFill))
                    .frame(width: HLSize.callButton, height: HLSize.callButton)
                    .background(Circle().fill(Color.hl(fill)))
                    .opacity(isEnabled ? 1 : 0.5)
                Text(title).hlTextStyle(.macFootnote)
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(Text(title))
    }
}
