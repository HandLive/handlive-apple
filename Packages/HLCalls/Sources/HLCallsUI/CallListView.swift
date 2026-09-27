import HLCalls
import HLDesignSystem
import HLLocalization
import HLProtocol
import SwiftUI

/// The call list (CALL-04 fields 1–6, 12): the permission hint when the phone may not read its call log, then the
/// entries newest first, loading more as the list scrolls. Shown in the Messages window's Calls item on the Mac and in
/// the Calls tab on iPhone and iPad; while it is on screen its missed calls are seen (step 12).
public struct CallListView: View {
    @ObservedObject var model: CallsModel

    public init(model: CallsModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if model.status == .permissionMissing {
                Label(L10n.Call.callLogPermissionHint, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.hl(.textOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.entries.isEmpty, model.status != .permissionMissing {
                CallsEmptyView()
            }
            ForEach(model.entries) { record in
                CallRowView(record: record, simLabel: model.simLabel(subId: record.subId))
                    .onAppear { if record.id == model.entries.last?.id { model.loadMore() } }
            }
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }

}

/// Field 1 with no entries yet, like SMS-03 E1: "No Calls Yet" · "Calls from your phone appear here after the first
/// sync."
public struct CallsEmptyView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: HLSpacing.space8) {
            Image(systemName: "phone").font(.largeTitle).foregroundStyle(Color.secondary)
            Text(L10n.Call.emptyTitle).font(.headline)
            Text(L10n.Call.emptyBody).font(.subheadline).foregroundStyle(Color.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpacing.space40)
        .accessibilityElement(children: .combine)
    }
}

/// One call: the type symbol, the caller (a missed call in `text-red`, bold until seen), the SIM label and duration,
/// and the time (CALL-04 fields 2–6).
struct CallRowView: View {
    let record: CallLogRecord
    let simLabel: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpacing.space12) {
            Image(systemName: CallDisplay.symbol(record.type))
                .foregroundStyle(record.type == .missed ? Color.hl(.textRed) : Color.secondary)
                .frame(minWidth: HLSpacing.space20)
            VStack(alignment: .leading, spacing: HLSpacing.space4) {
                Text(CallDisplay.title(record))
                    .fontWeight(record.isUnseenMissed ? .bold : .regular)
                    .foregroundStyle(record.type == .missed ? Color.hl(.textRed) : Color.primary)
                let details = CallDisplay.details(record, simLabel: simLabel)
                if !details.isEmpty {
                    HStack(spacing: HLSpacing.space8) {
                        ForEach(details, id: \.self) { Text($0) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: HLSpacing.space8)
            Text(CallDisplay.listTime(record.ts)).font(.subheadline).foregroundStyle(Color.secondary)
        }
        .padding(.vertical, HLSpacing.space4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CallDisplay.accessibilityLabel(record, simLabel: simLabel))
    }
}
