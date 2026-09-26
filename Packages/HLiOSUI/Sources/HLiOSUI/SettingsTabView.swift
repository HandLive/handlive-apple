#if os(iOS)
import HLAppCore
import HLDesignSystem
import HLLocalization
import HLSMSUI
import SwiftUI
import UIKit

/// The Settings tab (2-patterns/04-cai-dat.md, iOS; SET-02): `GroupedList` in the order Phone · Clipboard · Messages ·
/// Internet Connection · Permissions · Data; reasons in `text-orange` under a row that can't work yet.
struct SettingsTabView: View {
    @ObservedObject var model: IOSAppModel
    let pair: () -> Void
    @State private var confirmingUnpair = false
    @State private var unpairResult: String?

    var body: some View {
        NavigationStack {
            GroupedList {
                phoneSection
                clipboardSection
                if let messages = model.messages { MessagesSettingsSection(model: model, messages: messages) }
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

    private var phoneSection: some View {
        GroupedSection(L10n.Settings.phone) {
            if let device = model.pairedDevice {
                VStack(alignment: .leading, spacing: HLSpacing.space4) {
                    Text(verbatim: device.peerName).font(.headline)
                    StatusIndicator(model.connectionStatus, deviceName: device.peerName).font(.subheadline)
                }
                GroupedActionRow(L10n.Pairing.unpair, role: .destructive) { confirmingUnpair = true }
                    .confirmationDialog(L10n.Pairing.unpairConfirmTitle(deviceName: device.peerName),
                                        isPresented: $confirmingUnpair, titleVisibility: .visible) {
                        Button(L10n.Pairing.unpair, role: .destructive) { unpair(device.peerName) }
                        Button(L10n.Common.cancel, role: .cancel) {}
                    } message: {
                        Text(L10n.Pairing.unpairConfirmMessage(deviceName: model.device.name))
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
                                    unavailableReason: model.notificationPermission == .denied
                                        ? L10n.Setup.notificationsDeniedIos : nil)
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

    private func unpair(_ name: String) {
        Task {
            let result = await model.unpair()
            unpairResult = result == .done ? L10n.Pairing.unpaired : L10n.Pairing.unpairedPending(deviceName: name)
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
