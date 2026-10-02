import HLAppCore
import HLCallNotifications
import HLLocalization
import SwiftUI

/// The ringing call in the menu bar menu (MenuBarMenu README: also after "Ignore" and while a Focus hides the panel):
/// the caller, then "Answer" and "Decline" as `controls` allow, for this call only: once it is gone they do nothing.
struct RingingCallItems: View {
    let call: ActiveCall
    @ObservedObject var calls: MacCalls

    var body: some View {
        Divider()
        Text(CallNames.title(call.caller))
        if call.state.controls.answer {
            Button(L10n.Call.answer) { calls.command(.answer(.phone), for: call.callId, from: .menu) }
                .disabled(call.command != nil)
        }
        if call.state.controls.reject {
            Button(L10n.Call.decline) { calls.command(.reject(reply: nil), for: call.callId, from: .menu) }
                .disabled(call.command != nil)
        }
    }
}

/// A missed call among the recent items (CALL-04 API 4 logic 5): the caller, and "Missed call · 2:05 PM" (with the
/// SIM label) under it; choosing it opens the call list.
struct MissedCallItem: View {
    let missed: MissedCall
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Text(CallNames.title(missed.caller))
            Text(CallNotificationBuilder.missed(missed, canMessage: false).body)
        }
    }
}
