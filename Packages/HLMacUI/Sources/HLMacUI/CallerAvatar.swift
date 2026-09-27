import HLAppCore
import HLDesignSystem
import HLSMSNotifications
import SwiftUI

/// The caller's avatar: initials on the Contacts gray, or a person symbol for a number.
struct CallerAvatar: View {
    let caller: CallerIdentity
    private let side: CGFloat = HLSize.avatar

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.53)], startPoint: .top,
                                         endPoint: .bottom))
            if case .name(let name) = caller, let initials = InitialsAvatar.initials(of: name) {
                Text(initials).font(.system(size: side * 0.42, weight: .medium)).foregroundStyle(Color.white)
            } else {
                Image(systemName: "person.fill").font(.system(size: side * 0.5)).foregroundStyle(Color.white)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
