#if os(iOS)
import HLDesignSystem
import HLLocalization
import SwiftUI

/// Data (SET-02 fields 26–30): "Remove Device from Server" and "Delete All HandLive Data", each confirmed in an action
/// sheet that states what goes, with the action named on the red button (field 28); the result or error underneath.
struct DataSettingsSection: View {
    @ObservedObject var model: IOSAppModel
    @State private var confirmingRemove = false
    @State private var confirmingDelete = false
    @State private var askingDeleteOffline = false
    @State private var working = false
    @State private var result: (text: String, isError: Bool)?

    var body: some View {
        GroupedSection(L10n.Settings.data) {
            GroupedActionRow(L10n.Settings.removeFromServer) { confirmingRemove = true }
                .disabled(!model.canRemoveFromServer || working)
                .confirmationDialog(L10n.Settings.removeFromServer, isPresented: $confirmingRemove,
                                    titleVisibility: .visible) {
                    Button(L10n.Settings.removeFromServerConfirm, role: .destructive) { removeFromServer() }
                    Button(L10n.Common.cancel, role: .cancel) {}
                } message: {
                    Text(L10n.Settings.removeFromServerWarning)
                }
            GroupedActionRow(L10n.Settings.deleteAllData, role: .destructive) { confirmingDelete = true }
                .disabled(working)
                .confirmationDialog(L10n.Settings.deleteAllData, isPresented: $confirmingDelete,
                                    titleVisibility: .visible) {
                    Button(L10n.Settings.deleteAllConfirm, role: .destructive) { deleteAll(evenIfOffline: false) }
                    Button(L10n.Common.cancel, role: .cancel) {}
                } message: {
                    Text(L10n.Settings.deleteAllDataWarning)
                }
                .alert(L10n.Settings.deleteAllOfflineConfirm, isPresented: $askingDeleteOffline) {
                    Button(L10n.Common.delete, role: .destructive) { deleteAll(evenIfOffline: true) }
                    Button(L10n.Common.cancel, role: .cancel) {}
                }
            if working { ProgressView() }
            if let result {
                Text(result.text)
                    .font(.footnote)
                    .foregroundStyle(result.isError ? HLColorToken.textOrange.color : Color.secondary)
            }
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

    /// E7 asks again when the relay can't be reached; once everything is deleted the app starts over at setup.
    private func deleteAll(evenIfOffline: Bool) {
        working = true
        Task {
            let outcome = await model.deleteAllData(evenIfOffline: evenIfOffline)
            working = false
            if outcome == .serverUnreachable { askingDeleteOffline = true }
        }
    }
}
#endif
