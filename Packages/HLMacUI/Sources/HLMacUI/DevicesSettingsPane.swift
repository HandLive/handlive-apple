import HLAppCore
import HLDesignSystem
import HLLocalization
import HLSMS
import HLSMSUI
import SwiftUI

/// Settings › Devices (PAIR-02, DeviceRow README): the paired phone with its status, "Details…" and "Unpair…", or
/// the empty state with "Add Phone…".
struct DevicesSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var showingDetails = false
    @State private var confirmingUnpair = false
    @State private var pairing = false
    /// Feedback after pairing from Settings: a short status line in the open window (Feedback README, macOS).
    @State private var pairedName: String?

    var body: some View {
        Form {
            if let device = model.pairedDevice {
                Section {
                    HStack(spacing: HLSpacing.space12) {
                        Image(systemName: "candybarphone")
                            .font(.title2)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(HLColorToken.tertiarySystemFill.color))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: HLSpacing.space4) {
                            Text(verbatim: device.peerName).hlTextStyle(.macHeadline).lineLimit(1).truncationMode(.tail)
                            StatusIndicator(model.connectionStatus, deviceName: device.peerName).hlTextStyle(.macSubheadline)
                        }
                        Spacer()
                        Button(L10n.Pairing.details) { showingDetails = true }
                        Button(L10n.Pairing.unpairEllipsis) { confirmingUnpair = true }
                    }
                }
            } else {
                Section {
                    EmptyPhoneState { pairing = true }
                }
            }
            if let pairedName {
                Section {
                    Label(L10n.Pairing.pairedWith(deviceName: pairedName), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(HLColorToken.statusConnected.color)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPairOnRelay() }
        .sheet(isPresented: $pairing) {
            PairingSheet(model: model, onPaired: { name in
                pairing = false
                pairedName = name
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    pairedName = nil
                }
            }, cancel: { pairing = false })
        }
        .sheet(isPresented: $showingDetails) {
            if let device = model.pairedDevice {
                DeviceDetailView(model: model, device: device, confirmingUnpair: $confirmingUnpair) {
                    showingDetails = false
                }
            }
        }
        .unpairAlert(model: model, isPresented: $confirmingUnpair)
    }
}

/// "No Phone Yet" with the next step (05-phan-hoi-va-tai.md, empty states).
struct EmptyPhoneState: View {
    let addPhone: () -> Void

    var body: some View {
        VStack(spacing: HLSpacing.space12) {
            Text(L10n.Pairing.emptyTitleClient).hlTextStyle(.brandTitle)
            Text(L10n.Pairing.emptyBodyClient).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(L10n.Pairing.addPhone, action: addPhone)
                .hlButtonStyle(.prominent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpacing.space20)
    }
}

/// Details of the paired phone: status, effective features with reasons, missing permissions, Security Code.
struct DeviceDetailView: View {
    @ObservedObject var model: AppModel
    let device: PairedDeviceRecord
    @Binding var confirmingUnpair: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent { StatusIndicator(model.connectionStatus, deviceName: device.peerName) } label: {
                        Text(verbatim: device.peerName).hlTextStyle(.macHeadline)
                    }
                }
                Section { // field 8: the features in use, each with its reason when it isn't
                    featureRow(L10n.Settings.clipboard, reason: model.clipboardUnavailableReason)
                    featureRow(L10n.Settings.smsMessages, reason: model.smsFeatureReason)
                    featureRow(L10n.Settings.calls, reason: model.callsFeatureReason)
                }
                MissingPermissionsSection(permissions: device.peerCapability?.permissionsMissing ?? [],
                                          callsOnPhone: device.peerCapability?.features.call?.enabled == true)
                Section {
                    LabeledContent(L10n.Pairing.securityCode) {
                        Text(verbatim: device.securityCode)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button(L10n.Pairing.unpairEllipsis) {
                        close()
                        confirmingUnpair = true
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.Common.done, action: close).keyboardShortcut(.defaultAction)
            }
            .padding(HLSpacing.space16)
        }
        .frame(width: 440)
    }
}

extension DeviceDetailView {
    private func featureRow(_ name: String, reason: String?) -> some View {
        LabeledContent(name) {
            if let reason {
                Text(reason).foregroundStyle(HLColorToken.textOrange.color)
            } else {
                Text(L10n.Common.on).foregroundStyle(.secondary)
            }
        }
    }
}

/// PAIR-02 field 9: the permissions missing on the phone. A missing `READ_SMS`/`SEND_SMS` opens the SMS instructions
/// (SMS-01 field 7) through "View Instructions"; contacts get their hint; the others get their instructions with their
/// phases.
struct MissingPermissionsSection: View {
    let permissions: [String]
    /// Calls are on on the phone: its missing phone-state and contacts permissions count as call permissions too.
    var callsOnPhone = false
    @State private var showingCallInstructions = false

    var body: some View {
        if !permissions.isEmpty {
            Section {
                if SmsPermissions.smsMissing(in: permissions) { SmsPhoneProblemRow(.missingPermission) }
                if SmsPermissions.contactsMissing(in: permissions) { reason(L10n.Sms.contactsPermissionHint) }
                if permissions.contains(where: { Self.isCall($0, callsOnPhone: callsOnPhone) }) {
                    VStack(alignment: .leading, spacing: HLSpacing.space8) {
                        reason(L10n.Pairing.reasonMissingPermission)
                        Button(L10n.Common.viewInstructionsEllipsis) { showingCallInstructions = true }
                    }
                }
                if permissions.contains(where: { Self.hasOwnPhase($0, callsOnPhone: callsOnPhone) }) {
                    reason(L10n.Pairing.reasonMissingPermission)
                }
            }
            .alert(L10n.Call.permissionInstructionsTitle, isPresented: $showingCallInstructions) {
                Button(L10n.Common.ok) {}.keyboardShortcut(.defaultAction)
            } message: {
                Text(L10n.Call.permissionInstructionsBody)
            }
        }
    }

    /// PAIR-02 field 9: `READ_CALL_LOG` and `ANSWER_PHONE_CALLS`, and `READ_PHONE_STATE` and `READ_CONTACTS` while calls
    /// are on on the phone, open the call permission instructions.
    static func isCall(_ permission: String, callsOnPhone: Bool) -> Bool {
        if CallPermissions.matches(permission, CallPermissions.callLog)
            || CallPermissions.matches(permission, CallPermissions.answer) { return true }
        return callsOnPhone && (CallPermissions.matches(permission, CallPermissions.phoneState)
            || CallPermissions.matches(permission, CallPermissions.contacts))
    }

    /// A permission of a later feature (camera…), neither SMS, contacts nor calls.
    static func hasOwnPhase(_ permission: String, callsOnPhone: Bool = false) -> Bool {
        !SmsPermissions.isSms(permission) && !SmsPermissions.matches(permission, SmsPermissions.contacts)
            && !isCall(permission, callsOnPhone: callsOnPhone)
    }

    private func reason(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .hlTextStyle(.macFootnote)
            .foregroundStyle(HLColorToken.textOrange.color)
    }
}

extension View {
    /// Unpair confirmation on the Mac (Alert README, PAIR-03 field 3): "Cancel" on the left, "Unpair" the default
    /// action on the right, not red, because the user chose it.
    func unpairAlert(model: AppModel, isPresented: Binding<Bool>) -> some View {
        let name = model.pairedDevice?.peerName ?? ""
        return alert(L10n.Pairing.unpairConfirmTitle(deviceName: name), isPresented: isPresented) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Pairing.unpair) { Task { await model.unpair() } }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(L10n.Pairing.unpairConfirmMessage(deviceName: name))
        }
    }
}
