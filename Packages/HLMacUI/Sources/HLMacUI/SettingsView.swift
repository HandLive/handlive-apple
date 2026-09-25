import HLAppCore
import HLDesignSystem
import HLLocalization
import SwiftUI

/// Settings window (2-patterns/04-cai-dat.md, macOS): one pane per feature group, each a grouped `Form`. Phase 1
/// ships the panes of the features it has — General, Devices, Clipboard; Messages, Calls and Camera join with
/// their phases.
public struct SettingsView: View {
    @ObservedObject var model: AppModel
    let actions: AppActions

    public init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        TabView {
            GeneralSettingsPane(model: model)
                .tabItem { Label(L10n.Settings.general, systemImage: "gearshape") }
            DevicesSettingsPane(model: model, actions: actions)
                .tabItem { Label(L10n.Pairing.devices, systemImage: "candybarphone") }
            ClipboardSettingsPane(model: model)
                .tabItem { Label(L10n.Settings.clipboard, systemImage: "doc.on.clipboard") }
        }
        .frame(width: 520)
        .onAppear { model.refreshSystemState() }
    }
}

/// General: menu bar icon, login item, Internet connection (SET-02 fields 21, 22, 31).
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
            Section {
                Toggle(L10n.Settings.internetConnection, isOn: Binding(get: { model.relayEnabled },
                                                                      set: { model.setRelayEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
            }
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
