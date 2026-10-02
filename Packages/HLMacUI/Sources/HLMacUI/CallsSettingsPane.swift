import HLAppCore
import HLCalls
import HLDesignSystem
import HLLocalization
import SwiftUI

/// Settings › Calls (2-patterns/04-cai-dat.md; SET-02 fields 10–12 and 33, CALL-04 field 11): the Calls switch with
/// its reason when calls can't work, the Call Notifications and Ring on Mac checkboxes (with the Focus hint), when the
/// call log last synced, and the Quick Replies list. Calls from Other Apps (CALL-05, SET-02 field 38) is a checkbox under
/// the Calls switch, with its footer and the phone's reason when the phone cannot send them. Take Calls on Mac joins with
/// Phase 4.
struct CallsSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calls: MacCalls

    var body: some View {
        Form {
            Section {
                Toggle(L10n.Settings.calls, isOn: Binding(get: { calls.callsEnabled }, set: { calls.setCallsEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                if let reason = model.callsFeatureReason, calls.callsEnabled {
                    Label(reason, systemImage: "info.circle")
                        .hlTextStyle(.macFootnote)
                        .foregroundStyle(HLColorToken.textOrange.color)
                }
                Group {
                    Toggle(L10n.Settings.callNotify, isOn: Binding(get: { calls.callNotify },
                                                                  set: { calls.setCallNotify($0) }))
                    Toggle(L10n.Settings.callRingtone, isOn: Binding(get: { calls.callRingtone },
                                                                    set: { calls.setCallRingtone($0) }))
                    if calls.callRingtone, calls.focusAvailable, !calls.focusAuthorized {
                        GuidanceRow(text: L10n.Settings.focusPermissionHint, pane: .focus)
                    }
                    appCallsOption
                }
                .toggleStyle(.checkbox)
                .padding(.leading, HLSpacing.space20)
                .disabled(!calls.callsEnabled) // dimmed, never hidden (Toggle README)
            }
            if let list = calls.list {
                CallLogSyncSection(list: list)
            }
            QuickRepliesSection(calls: calls)
        }
        .formStyle(.grouped)
        .onAppear { calls.refreshFocus() }
    }

    /// "Calls from Other Apps": the checkbox, what it does, and why it does nothing when the phone lacks Notification
    /// access or turned it off.
    @ViewBuilder
    private var appCallsOption: some View {
        Toggle(L10n.Settings.callAppCalls, isOn: Binding(get: { calls.callAppCalls },
                                                        set: { calls.setCallAppCalls($0) }))
        Text(L10n.Settings.callAppCallsFooter).hlTextStyle(.macFootnote).foregroundStyle(.secondary)
        if let reason = model.appCallsFeatureReason {
            Label(reason, systemImage: "info.circle")
                .hlTextStyle(.macFootnote)
                .foregroundStyle(HLColorToken.textOrange.color)
        }
    }
}

/// "Last synced: 5 minutes ago" (CALL-04 field 11) and the call log permission hint (field 12).
struct CallLogSyncSection: View {
    @ObservedObject var list: CallsModel

    var body: some View {
        if list.lastSyncAt != nil || list.status == .permissionMissing {
            Section {
                if let time = list.lastSyncAt {
                    Text(L10n.Settings.callLogLastSync(time: SmsSyncSection.relative(time))).foregroundStyle(Color.secondary)
                }
                if list.status == .permissionMissing {
                    Label(L10n.Call.callLogPermissionHint, systemImage: "info.circle")
                        .hlTextStyle(.macFootnote)
                        .foregroundStyle(HLColorToken.textOrange.color)
                }
            }
        }
    }
}

/// "Quick Replies" (CALL-02 field 8, SET-02 field 33): add, edit, remove and reorder, at most 6 of 160 characters.
struct QuickRepliesSection: View {
    @ObservedObject var calls: MacCalls
    @State private var drafts: [Draft] = []

    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    var body: some View {
        Section {
            List {
                ForEach($drafts) { $draft in
                    HStack {
                        TextField(L10n.Settings.quickReplies, text: Binding(
                            get: { draft.text },
                            set: { draft.text = String($0.prefix(AppSettings.quickReplyMaxCharacters)) }))
                            .labelsHidden()
                            .onSubmit(save)
                        Button {
                            drafts.removeAll { $0.id == draft.id }
                            save()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.Settings.quickReplyRemove)
                        .accessibilityLabel(Text(L10n.Settings.quickReplyRemove))
                    }
                }
                .onMove { from, to in
                    drafts.move(fromOffsets: from, toOffset: to)
                    save()
                }
            }
            .frame(minHeight: CGFloat(max(drafts.count, 1)) * 28)
            Button(L10n.Settings.quickReplyAdd) { drafts.append(Draft(text: "")) }
                .disabled(drafts.count >= AppSettings.quickRepliesMax)
        } header: {
            Text(L10n.Settings.quickReplies)
        } footer: {
            Text(L10n.Settings.quickRepliesFooter).hlTextStyle(.macFootnote).foregroundStyle(.secondary)
        }
        .disabled(!calls.callsEnabled)
        .onAppear { drafts = calls.quickReplies.map { Draft(text: $0) } }
        .onDisappear(perform: save)
    }

    /// Empty templates are dropped when saved.
    private func save() {
        calls.setQuickReplies(drafts.map(\.text))
    }
}
