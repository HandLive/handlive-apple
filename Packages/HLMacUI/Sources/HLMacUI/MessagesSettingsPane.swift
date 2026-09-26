import HLDesignSystem
import HLLocalization
import HLSMSUI
import SwiftUI

/// Settings › Messages (2-patterns/04-cai-dat.md; SET-02 fields 7–9 and 25, SMS-01 fields 4–6 and 8): the SMS switch
/// with its reason when SMS can't work and its two checkboxes, the last sync with "Resync All SMS…", the contacts
/// hint and the read-state caption.
struct MessagesSettingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(L10n.Settings.smsMessages, isOn: Binding(get: { model.smsEnabled }, set: { model.setSmsEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                if let reason = model.smsUnavailableReason {
                    Label(reason, systemImage: "info.circle")
                        .hlTextStyle(.macFootnote)
                        .foregroundStyle(HLColorToken.textOrange.color)
                }
                Group {
                    Toggle(L10n.Settings.smsNotify, isOn: Binding(get: { model.smsNotify }, set: { model.setSmsNotify($0) }))
                    Toggle(L10n.Settings.smsPreview, isOn: Binding(get: { model.smsPreview },
                                                                  set: { model.setSmsPreview($0) }))
                }
                .toggleStyle(.checkbox)
                .padding(.leading, HLSpacing.space20)
                .disabled(!model.smsEnabled) // dimmed, never hidden (Toggle README)
            }
            if let messages = model.messages {
                SmsSyncSection(model: model, messages: messages)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Last synced: 5 minutes ago" and "Resync All SMS…" with its confirmation (SMS-01 fields 4–6, A1–A2).
struct SmsSyncSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var messages: MessagesModel
    @State private var confirmingResync = false

    var body: some View {
        Section {
            HStack {
                if let time = messages.lastSyncAt {
                    Text(L10n.Settings.smsLastSync(time: Self.relative(time))).foregroundStyle(Color.secondary)
                }
                Spacer()
                Button(L10n.Settings.resyncSmsEllipsis) { confirmingResync = true }
                    .disabled(!model.canResyncSms) // needs a session to the phone (field 25)
            }
            if model.phoneMissesContactsPermission {
                Label(L10n.Sms.contactsPermissionHint, systemImage: "info.circle")
                    .hlTextStyle(.macFootnote)
                    .foregroundStyle(HLColorToken.textOrange.color)
            }
        } footer: {
            Text(L10n.Settings.smsReadNote).hlTextStyle(.macFootnote).foregroundStyle(.secondary)
        }
        .alert(L10n.Sms.resyncConfirmTitle(deviceName: model.device.name), isPresented: $confirmingResync) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Sms.resync) { Task { await model.resyncAllSms() } }
        } message: {
            Text(L10n.Sms.resyncConfirmMessage)
        }
    }

    /// "5 minutes ago" in the display language (SMS-01 field 4).
    static func relative(_ ms: Int64, now: Date = Date()) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), relativeTo: now)
    }
}
