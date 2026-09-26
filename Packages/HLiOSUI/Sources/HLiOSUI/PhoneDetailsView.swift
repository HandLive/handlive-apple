#if os(iOS)
import HLAppCore
import HLDesignSystem
import HLLocalization
import HLSMS
import HLSMSUI
import SwiftUI

/// The phone's details (PAIR-02, DeviceRow README): its status, the features in use with the reason one isn't (field
/// 8), the permissions missing on the phone (field 9 — a missing SMS permission opens the SMS-01 field 7 alert), the
/// Security Code (field 10) and "Unpair" in the last group (field 12, PAIR-03).
struct PhoneDetailsView: View {
    @ObservedObject var model: IOSAppModel
    let device: PairedDeviceRecord
    /// "Unpaired" or "Unpaired; <phone> will clean up when it reconnects" for the Phone group (PAIR-03 field 4).
    let unpaired: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false
    @State private var showingSmsInstructions = false

    var body: some View {
        GroupedList {
            GroupedSection {
                VStack(alignment: .leading, spacing: HLSpacing.space4) {
                    Text(verbatim: device.peerName).font(.headline)
                    StatusIndicator(model.connectionStatus, deviceName: device.peerName).font(.subheadline)
                }
            }
            GroupedSection {
                feature(L10n.Settings.clipboard, reason: model.clipboardFeatureReason)
                feature(L10n.Settings.smsMessages, reason: model.smsFeatureReason)
            }
            missingPermissions
            GroupedSection {
                LabeledContent(L10n.Pairing.securityCode) {
                    Text(verbatim: device.securityCode).font(.body.monospaced().weight(.semibold)).textSelection(.enabled)
                }
            }
            GroupedSection {
                GroupedActionRow(L10n.Pairing.unpair, role: .destructive) { confirmingUnpair = true }
            }
        }
        .navigationTitle(device.peerName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(L10n.Pairing.unpairConfirmTitle(deviceName: device.peerName), isPresented: $confirmingUnpair,
                            titleVisibility: .visible) {
            Button(L10n.Pairing.unpair, role: .destructive) { unpair() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Pairing.unpairConfirmMessage(deviceName: model.device.name))
        }
        .smsPermissionInstructions(isPresented: $showingSmsInstructions)
        .onAppear { model.refreshPairOnRelay() }
    }

    private func feature(_ name: String, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: HLSpacing.space4) {
            Text(name)
            Text(reason ?? L10n.Common.on)
                .font(.footnote)
                .foregroundStyle(reason == nil ? Color.secondary : HLColorToken.textOrange.color)
        }
        .accessibilityElement(children: .combine)
    }

    /// Field 9: selecting the SMS row opens the instructions; contacts get their hint, the rest a general reason.
    @ViewBuilder
    private var missingPermissions: some View {
        let permissions = device.peerCapability?.permissionsMissing ?? []
        if !permissions.isEmpty {
            GroupedSection {
                if SmsPermissions.smsMissing(in: permissions) {
                    Button { showingSmsInstructions = true } label: {
                        LabeledContent {
                            Image(systemName: "info.circle").accessibilityHidden(true)
                        } label: {
                            reason(L10n.Pairing.reasonMissingSmsPermission)
                        }
                    }
                    .accessibilityHint(Text(L10n.Common.viewInstructions))
                }
                if SmsPermissions.contactsMissing(in: permissions) { reason(L10n.Sms.contactsPermissionHint) }
                if permissions.contains(where: Self.hasOwnPhase) { reason(L10n.Pairing.reasonMissingPermission) }
            }
        }
    }

    /// A permission of a later feature (calls, camera…), neither SMS nor contacts.
    static func hasOwnPhase(_ permission: String) -> Bool {
        !SmsPermissions.isSms(permission) && !SmsPermissions.matches(permission, SmsPermissions.contacts)
    }

    private func reason(_ text: String) -> some View {
        Text(text).foregroundStyle(HLColorToken.textOrange.color)
    }

    private func unpair() {
        let name = device.peerName
        Task {
            let result = await model.unpair()
            unpaired(result == .done ? L10n.Pairing.unpaired : L10n.Pairing.unpairedPending(deviceName: name))
            dismiss()
        }
    }
}
#endif
