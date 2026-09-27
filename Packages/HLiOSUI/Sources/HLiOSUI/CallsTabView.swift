#if os(iOS)
import HLCalls
import HLCallsUI
import HLLocalization
import SwiftUI

/// The Calls tab (02-ios-ipados.md; CALL-04 fields 1–7 and 12): the call log newest first in a plain list under a large
/// title, with the call log permission hint. One column on iPhone and iPad alike: a call has no screen of its own to
/// show beside the list. Opening it marks the pair's missed calls as seen (step 12).
struct CallsTabView: View {
    @ObservedObject var calls: IOSCalls

    var body: some View {
        NavigationStack {
            Group {
                if let list = calls.list {
                    CallListView(model: list).listStyle(.plain)
                } else {
                    CallsEmptyView() // no database here (SMS-01 E7): nothing can be kept
                }
            }
            .navigationTitle(L10n.Call.title)
        }
        .badge(missedBadge)
    }

    /// Unseen missed calls (CALL-04 field 7), which VoiceOver reads as "3 missed calls"; none at 0.
    private var missedBadge: Text? {
        let count = calls.missedBadge
        guard count > 0 else { return nil }
        return Text(verbatim: String(count)).accessibilityLabel(Text(L10n.A11y.missedCalls(count: count)))
    }
}
#endif
