import HLAppCore
import HLDesignSystem
import HLLocalization
import SwiftUI

/// Settings window (2-patterns/04-cai-dat.md, macOS): one pane per feature group, each a grouped `Form` — General,
/// Devices, Clipboard, Messages and Calls so far; Camera joins with its phase.
public struct SettingsView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            GeneralSettingsPane(model: model)
                .tabItem { Label(L10n.Settings.general, systemImage: "gearshape") }
            PermissionsSettingsPane(model: model)
                .tabItem { Label(L10n.Settings.permissions, systemImage: "lock.shield") }
            DevicesSettingsPane(model: model)
                .tabItem { Label(L10n.Pairing.devices, systemImage: "candybarphone") }
            ClipboardSettingsPane(model: model)
                .tabItem { Label(L10n.Settings.clipboard, systemImage: "doc.on.clipboard") }
            MessagesSettingsPane(model: model)
                .tabItem { Label(L10n.Settings.messages, systemImage: "message") }
            CallsSettingsPane(model: model, calls: model.calls)
                .tabItem { Label(L10n.Settings.calls, systemImage: "phone") }
        }
        .frame(width: 520)
        .onAppear {
            model.refreshSystemState()
            SettingsOpener.settingsDidAppear(model: model)
        }
        .onDisappear {
            SettingsOpener.settingsDidDisappear(model: model)
        }
    }
}

/// Permissions: notifications, local network and paste access (SET-03 fields 7, 9, 10).
struct PermissionsSettingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                permissionRow(title: L10n.Settings.notifications, value: notificationsValue,
                              reason: model.notificationPermission == .denied
                                  ? L10n.Setup.notificationsDeniedMac : nil,
                              pane: .notifications)
                permissionRow(title: L10n.Settings.localNetwork, value: localNetworkValue,
                              reason: model.localNetworkAccess == .denied
                                  ? L10n.Setup.localNetworkDeniedMac : nil,
                              pane: .localNetwork)
                if model.pasteAccess.needsGuide {
                    permissionRow(title: L10n.Settings.pasteFromOtherApps, value: pasteValue,
                                  reason: L10n.Settings.pastePermissionHint,
                                  pane: .privacyAndSecurity)
                } else if #available(macOS 15.4, *) {
                    permissionRow(title: L10n.Settings.pasteFromOtherApps, value: pasteValue,
                                  reason: nil, pane: .privacyAndSecurity)
                }
            } footer: {
                Text(L10n.Settings.permissionsFooterMac)
                    .hlTextStyle(.macFootnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    Task { await model.refreshPermissionStatuses(probeLocalNetwork: true) }
                } label: {
                    HStack {
                        Text(L10n.Settings.checkAgain)
                        if model.checkingPermissions {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.checkingPermissions)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await model.refreshPermissionStatuses(probeLocalNetwork: true) }
        }
    }

    private var notificationsValue: String {
        switch model.notificationPermission {
        case .allowed: L10n.Common.on
        case .denied: L10n.Common.off
        case .notDetermined: L10n.Settings.localNetworkUnknown
        }
    }

    private var localNetworkValue: String {
        switch model.localNetworkAccess {
        case .allowed, .notRequired: L10n.Common.on
        case .denied: L10n.Common.off
        case .unknown: L10n.Settings.localNetworkUnknown
        }
    }

    private var pasteValue: String {
        switch model.pasteAccess {
        case .alwaysAllow, .standard, .notApplicable: L10n.Common.on
        case .ask, .alwaysDeny: L10n.Common.off
        }
    }

    private func permissionRow(title: String, value: String, reason: String?,
                               pane: SystemSettingsPane) -> some View {
        VStack(alignment: .leading, spacing: HLSpacing.space8) {
            LabeledContent(title) { Text(value) }
            if let reason {
                GuidanceRow(text: reason, pane: pane)
            }
        }
    }
}

/// General: menu bar icon, login item, the internet connection and the data actions (SET-02 fields 21, 22, 26–31).
struct GeneralSettingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(L10n.Settings.showInMenuBar, isOn: Binding(get: { model.showInMenuBar },
                                                                 set: { model.setShowInMenuBar($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
            } footer: {
                Text(L10n.Settings.showInMenuBarFooter).hlTextStyle(.macFootnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L10n.Settings.openAtLogin, isOn: Binding(get: { model.loginItemStatus == .enabled },
                                                               set: { model.setOpenAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                if model.loginItemStatus == .requiresApproval {
                    GuidanceRow(text: L10n.Setup.loginItemApprovalMac, pane: .loginItems)
                }
            }
            ServerSettingsSections(model: model)
        }
        .formStyle(.grouped)
    }
}

/// Clipboard: sync, images, sensitive content, auto-clear, paste permission (SET-02 fields 1, 4–6; CLIP-02 fields 2–3).
struct ClipboardSettingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(L10n.Settings.syncClipboard, isOn: Binding(get: { model.clipboardEnabled },
                                                                 set: { model.setClipboardEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                Group {
                    Toggle(L10n.Settings.syncImages, isOn: Binding(get: { model.sendImages }, set: { model.setSendImages($0) }))
                    Toggle(L10n.Settings.blockSensitive, isOn: Binding(get: { model.blockSensitive },
                                                                      set: { model.setBlockSensitive($0) }))
                }
                .toggleStyle(.checkbox)
                .padding(.leading, HLSpacing.space20)
                .disabled(!model.clipboardEnabled) // dimmed, never hidden (Toggle README)
                if model.pairedDevice?.peerCapability?.features.clipboard?.autoSend == false {
                    Label(L10n.Clipboard.autoSendOffOnPhone, systemImage: "info.circle")
                        .hlTextStyle(.macFootnote)
                        .foregroundStyle(HLColorToken.textOrange.color)
                }
            }
            Section {
                Picker(L10n.Settings.autoClear, selection: Binding(get: { model.autoClearSeconds },
                                                                   set: { model.setAutoClearSeconds($0) })) {
                    Text(L10n.Common.off).tag(0)
                    Text(L10n.Settings.autoClear1Min).tag(60)
                    Text(L10n.Settings.autoClear5Min).tag(300)
                }
            } footer: {
                Text(L10n.Settings.autoClearFooter).hlTextStyle(.macFootnote).foregroundStyle(.secondary)
            }
            if model.pasteAccess.needsGuide {
                Section(L10n.Settings.pasteFromOtherApps) {
                    GuidanceRow(text: L10n.Settings.pastePermissionHint, pane: .privacyAndSecurity)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A reason in `text-orange` with the button that opens the right page of System Settings (Toggle README).
struct GuidanceRow: View {
    let text: String
    let pane: SystemSettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpacing.space8) {
            Label(text, systemImage: "info.circle")
                .hlTextStyle(.macFootnote)
                .foregroundStyle(HLColorToken.textOrange.color)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.Common.openSystemSettings) { pane.open() }
        }
    }
}
