#if os(iOS)
import HLAppCore
import HLCalls
import HLDesignSystem
import HLLocalization
import HLSMSUI
import SwiftUI
import UIKit

/// The Settings tab (2-patterns/04-cai-dat.md, iOS; SET-02): `GroupedList` in the order Phone · Clipboard · Messages ·
/// Calls · Internet Connection · Permissions · Data; reasons in `text-orange` under a row that can't work yet.
struct SettingsTabView: View {
    @ObservedObject var model: IOSAppModel
    let pair: () -> Void
    @State private var unpairResult: String?

    var body: some View {
        NavigationStack {
            GroupedList {
                phoneSection
                clipboardSection
                if let messages = model.messages { MessagesSettingsSection(model: model, messages: messages) }
                CallsSettingsSection(model: model, calls: model.calls)
                GroupedSection {
                    Toggle(isOn: Binding(get: { model.relayEnabled }, set: { model.setRelayEnabled($0) })) {
                        GroupedRowLabel(L10n.Settings.internetConnection, systemImage: "globe", feature: .internet,
                                        unavailableReason: model.relayProblemText())
                    }
                }
                permissionsSection
                DataSettingsSection(model: model)
            }
            .navigationTitle(L10n.Settings.title)
        }
        .onAppear { model.refreshPairOnRelay() }
    }

    /// The phone's `DeviceRow`, which opens its details (PAIR-02); "Unpair" lives there (DeviceRow README).
    private var phoneSection: some View {
        GroupedSection(L10n.Settings.phone) {
            if let device = model.pairedDevice {
                NavigationLink {
                    PhoneDetailsView(model: model, device: device) { result in unpairResult = result }
                } label: {
                    HStack(spacing: HLSpacing.space12) {
                        Image(systemName: "candybarphone")
                            .font(.title2)
                            .frame(width: HLSize.avatar, height: HLSize.avatar)
                            .background(Circle().fill(HLColorToken.tertiarySystemFill.color))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: HLSpacing.space4) {
                            Text(verbatim: device.peerName).font(.headline).lineLimit(1).truncationMode(.tail)
                            StatusIndicator(model.connectionStatus, deviceName: device.peerName).font(.subheadline)
                        }
                    }
                }
            } else {
                GroupedActionRow(L10n.Pairing.addPhone, action: pair)
            }
            if let unpairResult { Text(unpairResult).font(.footnote).foregroundStyle(Color.secondary) }
        }
    }

    private var clipboardSection: some View {
        GroupedSection(L10n.Settings.clipboard, footer: L10n.Settings.autoClearFooter) {
            Toggle(isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) })) {
                GroupedRowLabel(L10n.Settings.syncClipboard, systemImage: "doc.on.clipboard", feature: .clipboard,
                                unavailableReason: model.clipboardUnavailableReason)
            }
            Toggle(L10n.Settings.syncImages, isOn: Binding(get: { model.sendImages }, set: { model.setSendImages($0) }))
                .disabled(!model.clipboardEnabled)
            Picker(L10n.Settings.autoClear, selection: Binding(get: { model.autoClearSeconds },
                                                               set: { model.setAutoClearSeconds($0) })) {
                Text(L10n.Common.off).tag(0)
                Text(L10n.Settings.autoClear1Min).tag(60)
                Text(L10n.Settings.autoClear5Min).tag(300)
            }
            .pickerStyle(.navigationLink)
        }
    }

    private var permissionsSection: some View {
        GroupedSection(L10n.Settings.permissions) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                LabeledContent {
                    Text(model.notificationPermission == .denied ? L10n.Common.off : L10n.Common.on)
                } label: {
                    GroupedRowLabel(L10n.Settings.notifications, systemImage: "bell.badge", feature: .notifications,
                                    unavailableReason: notificationsReason)
                }
            }
            .foregroundStyle(Color.primary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                GroupedRowLabel(L10n.Settings.localNetwork, systemImage: "wifi", feature: .devices,
                                unavailableReason: model.link.issue == .localNetworkDenied
                                    ? L10n.Setup.localNetworkDeniedIos : nil)
            }
            .foregroundStyle(Color.primary)
        }
    }

    /// Notifications off (SET-03 field 7), or on with Time Sensitive off, where a Focus may silence calls (field 8).
    private var notificationsReason: String? {
        if model.notificationPermission == .denied { return L10n.Setup.notificationsDeniedIos }
        return model.timeSensitive == .disabled ? L10n.Setup.timeSensitiveOff : nil
    }
}

/// Calls (SET-02 fields 10–11, CALL-04 fields 11–12): the Calls switch with the reason calls can't work with the phone,
/// Call Notifications, when the call log last synced and the call log permission hint. iPhone and iPad have no ringing
/// and no quick replies (Mac only).
struct CallsSettingsSection: View {
    @ObservedObject var model: IOSAppModel
    @ObservedObject var calls: IOSCalls

    var body: some View {
        GroupedSection(L10n.Settings.calls) {
            Toggle(isOn: Binding(get: { calls.callsEnabled }, set: { calls.setCallsEnabled($0) })) {
                GroupedRowLabel(L10n.Settings.calls, systemImage: "phone", feature: .calls,
                                unavailableReason: model.callsPhoneProblem)
            }
            Toggle(L10n.Settings.callNotify, isOn: Binding(get: { calls.callNotify }, set: { calls.setCallNotify($0) }))
                .disabled(!calls.callsEnabled)
            if let list = calls.list { CallLogSyncRows(list: list) }
        }
    }
}

/// "Last synced: 5 minutes ago" (CALL-04 field 11) and the call log permission hint (field 12).
struct CallLogSyncRows: View {
    @ObservedObject var list: CallsModel

    var body: some View {
        if let time = list.lastSyncAt {
            Text(L10n.Settings.callLogLastSync(time: RelativeDateTimeFormatter().localizedString(
                for: Date(timeIntervalSince1970: TimeInterval(time) / 1000), relativeTo: Date())))
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
        if list.status == .permissionMissing {
            Label(L10n.Call.callLogPermissionHint, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(HLColorToken.textOrange.color)
        }
    }
}

/// Messages (SET-02 fields 7–9 and 25; SMS-01 fields 4–6 and 8): the switches, "Resync All SMS" with its
/// confirmation, the last sync, the contacts hint and the read-state caption.
struct MessagesSettingsSection: View {
    @ObservedObject var model: IOSAppModel
    @ObservedObject var messages: MessagesModel
    @State private var confirmingResync = false

    var body: some View {
        GroupedSection(L10n.Settings.messages, footer: L10n.Settings.smsReadNote) {
            Toggle(isOn: Binding(get: { model.smsEnabled }, set: { model.setSmsEnabled($0) })) {
                GroupedRowLabel(L10n.Settings.smsMessages, systemImage: "message", feature: .messages,
                                unavailableReason: model.smsPhoneProblem?.text)
            }
            if model.smsPhoneProblem?.hasInstructions == true { SmsInstructionsButton() } // SMS-01 field 7
            Group {
                Toggle(L10n.Settings.smsNotify, isOn: Binding(get: { model.smsNotify }, set: { model.setSmsNotify($0) }))
                Toggle(L10n.Settings.smsPreview, isOn: Binding(get: { model.smsPreview },
                                                              set: { model.setSmsPreview($0) }))
            }
            .disabled(!model.smsEnabled)
            VStack(alignment: .leading, spacing: HLSpacing.space4) {
                GroupedActionRow(L10n.Settings.resyncSms) { confirmingResync = true }
                    .disabled(!model.canResyncSms)
                if let time = messages.lastSyncAt {
                    Text(L10n.Settings.smsLastSync(time: RelativeDateTimeFormatter().localizedString(
                        for: Date(timeIntervalSince1970: TimeInterval(time) / 1000), relativeTo: Date())))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
            }
            .confirmationDialog(L10n.Sms.resyncConfirmTitle(deviceName: model.device.name),
                                isPresented: $confirmingResync, titleVisibility: .visible) {
                Button(L10n.Sms.resync) { Task { await model.resyncAllSms() } }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Sms.resyncConfirmMessage)
            }
            if model.phoneMissesContactsPermission {
                Label(L10n.Sms.contactsPermissionHint, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(HLColorToken.textOrange.color)
            }
        }
    }
}
#endif
