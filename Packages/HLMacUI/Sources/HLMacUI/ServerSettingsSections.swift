import AppKit
import HLDesignSystem
import HLLocalization
import HLTransport
import SwiftUI

/// The internet part of Settings › General (2-patterns/04-cai-dat.md): the "Internet Connection" switch with the
/// relay's problem, "Remove Device from Server…" with its result (SET-02 fields 21, 26, 30), and the destructive
/// "Delete All HandLive Data…" (field 27). Each action is confirmed in an alert stating what goes (fields 28–29).
struct ServerSettingsSections: View {
    @ObservedObject var model: AppModel
    @State private var confirmingRemove = false
    @State private var confirmingDelete = false
    @State private var askingDeleteOffline = false
    @State private var working = false
    @State private var result: (text: String, isError: Bool)?

    var body: some View {
        Section {
            Toggle(L10n.Settings.internetConnection, isOn: Binding(get: { model.relayEnabled },
                                                                  set: { model.setRelayEnabled($0) }))
                .toggleStyle(.switch).controlSize(.mini)
            if let problem = model.relayProblemText() {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .hlTextStyle(.macFootnote)
                    .foregroundStyle(HLColorToken.textOrange.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: HLSpacing.space8) {
                Button(L10n.Settings.removeFromServerEllipsis) { confirmingRemove = true }
                    .disabled(!model.canRemoveFromServer || working)
                if working { ProgressView().controlSize(.small) }
            }
            if let result {
                Text(result.text)
                    .hlTextStyle(.macFootnote)
                    .foregroundStyle(result.isError ? HLColorToken.textOrange.color : Color.secondary)
            }
        }
        .alert(L10n.Settings.removeFromServerTitle, isPresented: $confirmingRemove) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Settings.removeFromServerConfirm, role: .destructive) { removeFromServer() }
        } message: {
            Text(L10n.Settings.removeFromServerWarning)
        }
        Section {
            Button(L10n.Settings.deleteAllDataEllipsis, role: .destructive) { confirmingDelete = true }
                .disabled(working)
                .alert(L10n.Settings.deleteAllOfflineConfirm, isPresented: $askingDeleteOffline) {
                    Button(L10n.Common.cancel, role: .cancel) {}
                    Button(L10n.Common.delete, role: .destructive) { deleteAll(evenIfOffline: true) }
                }
        }
        .alert(L10n.Settings.deleteAllDataTitle, isPresented: $confirmingDelete) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Settings.deleteAllConfirm, role: .destructive) { deleteAll(evenIfOffline: false) }
        } message: {
            Text(L10n.Settings.deleteAllDataWarning)
        }
    }

    private func removeFromServer() {
        working = true
        result = nil
        Task {
            let outcome = await model.removeFromServer()
            working = false
            result = outcome == .removed ? (L10n.Settings.removedFromServer, false) : (L10n.Error.serverUnreachable, true)
        }
    }

    /// E7 asks again when the relay can't be reached; once everything is deleted the welcome window takes over.
    private func deleteAll(evenIfOffline: Bool) {
        working = true
        let settingsWindow = NSApp.keyWindow
        Task {
            let outcome = await model.deleteAllData(evenIfOffline: evenIfOffline)
            working = false
            switch outcome {
            case .serverUnreachable: askingDeleteOffline = true
            case .deleted: settingsWindow?.close()
            }
        }
    }
}

extension AppModel {
    /// The relay's problem under the switch (CONN-03 E3, E6, E7), or the result of a relay account event.
    func relayProblemText(now: Date = Date()) -> String? {
        switch link.issue {
        case .relayUntrusted?: return L10n.Error.relayPinMismatch
        case .relayDeviceRemoved?: return L10n.Error.relayDeviceRevoked
        case .relayRateLimited?:
            let seconds = max(1, (link.nextRetry ?? now).timeIntervalSince(now).rounded(.up))
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = seconds >= 60 ? [.minute] : [.second]
            let duration = formatter.string(from: seconds >= 60 ? (seconds / 60).rounded(.up) * 60 : seconds) ?? ""
            return L10n.Error.relayRateLimited(duration: duration)
        default: return relayNotice
        }
    }
}
