import HLAppCore
import HLDesignSystem
import HLLocalization
import SwiftUI

/// Settings › Devices (PAIR-02, DeviceRow README): the paired phone with its status, "Details…" and "Unpair…", or
/// the empty state with "Add Phone…".
struct DevicesSettingsPane: View {
    @ObservedObject var model: AppModel
    let actions: AppActions
    @State private var showingDetails = false
    @State private var confirmingUnpair = false

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
                    EmptyPhoneState(actions: actions)
                }
            }
        }
        .formStyle(.grouped)
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
    let actions: AppActions

    var body: some View {
        VStack(spacing: HLSpacing.space12) {
            Text(L10n.Pairing.emptyTitleClient).hlTextStyle(.brandTitle)
            Text(L10n.Pairing.emptyBodyClient).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(L10n.Pairing.addPhone) { actions.showPairing() }
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
                Section {
                    LabeledContent(L10n.Settings.clipboard) {
                        if let reason = model.clipboardUnavailableReason {
                            Text(reason).foregroundStyle(HLColorToken.textOrange.color)
                        } else {
                            Text(L10n.Common.on).foregroundStyle(.secondary)
                        }
                    }
                    if !(device.peerCapability?.permissionsMissing ?? []).isEmpty {
                        Label(L10n.Pairing.reasonMissingPermission, systemImage: "info.circle")
                            .foregroundStyle(HLColorToken.textOrange.color)
                    }
                }
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
