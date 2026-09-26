import Foundation
import HLAppCore
import HLProtocol
import HLSMS
import HLTransport

/// Result of "Remove Device from Server" (SET-02 field 30).
public enum IOSServerRemovalResult: Equatable, Sendable {
    /// "Removed from the server": the pair keeps working on the LAN, the internet connection is off.
    case removed
    /// E5: no network or a relay error; nothing changed.
    case failed
}

/// Result of "Delete All HandLive Data" (SET-02 A2–A6).
public enum IOSDeleteAllResult: Equatable, Sendable {
    /// Everything is gone and the app starts over at setup.
    case deleted
    /// E7: the relay could not be reached; the user may delete from this device anyway.
    case serverUnreachable
}

extension IOSAppModel {
    /// "Remove Device from Server" can be used: this build has a relay (`HLRelayHost`) and the keys are loaded.
    public var canRemoveFromServer: Bool { relay != nil }

    /// SET-02 A1–A4 and A6 for field 26: `DELETE /v1/devices/me?revoke_pairs=false`; the pair stays with
    /// `relay_registered = 0` and `relay.enabled = false` goes to the phone in `capability/update` (C16).
    public func removeFromServer() async -> IOSServerRemovalResult {
        guard let api = relay?.api else { return .failed }
        do {
            try await api.deleteDevice(revokePairs: false)
        } catch {
            return .failed
        }
        for record in (try? store?.all()) ?? [] {
            try? store?.update(pairId: record.pairId) { $0.relayRegistered = false }
        }
        pairedDevice = try? store?.active()
        pushTokenSent = false
        setRelayEnabled(false)
        await manager?.setPhone(activePhone()) // registers the pair again once the relay is turned back on
        return .removed
    }

    /// SET-02 A2–A6 for field 27: the relay deletes this device and revokes its pairs, the phone gets `pair/revoke
    /// {reinstall}` on a LAN session while the keys still exist, then the keys, the SMS database, the pair store, the
    /// settings of the App Group and every notification go, and the app starts over (SET-03). Without the relay the
    /// answer is `.serverUnreachable` unless the user chose to delete anyway (E7).
    public func deleteAllData(evenIfOffline: Bool = false) async -> IOSDeleteAllResult {
        if !evenIfOffline, let api = relay?.api {
            do {
                try await api.deleteDevice(revokePairs: true)
            } catch {
                return .serverUnreachable
            }
        }
        if let record = pairedDevice, let session = await manager?.currentSession, session.route == .lan {
            _ = try? await session.request(.pair, op: "revoke", data: PairRevokeData(pairId: record.pairId, reason: .reinstall))
        }
        await stopForErasing()
        eraseLocalData()
        startOver()
        return .deleted
    }

    private func stopForErasing() async {
        linkEvents?.cancel()
        linkEvents = nil
        await manager?.stop()
        manager = nil
        relay = nil
        clipboard?.phoneDisconnected()
        clipboard = nil
        outboxExpiry?.cancel()
        outboxExpiry = nil
        smsEngine?.disconnected()
        smsEngine?.setPair(nil)
        smsEngine = nil
        messages?.close()
    }

    /// SET-02 API 7 in its order: the keys first, then the database and the pair store, settings and notifications.
    private func eraseLocalData() {
        try? secrets.deleteAll()
        if let database = messages?.store.database {
            try? database.deleteFiles()
        } else {
            try? SmsDatabase.removeFiles(at: smsDatabaseURL)
        }
        messages = nil
        try? FileManager.default.removeItem(at: pairStoreURL)
        settings.removeAll()
        if settings.defaults !== UserDefaults.standard {
            settings.defaults.removePersistentDomain(forName: Self.appGroup)
        }
        notifications.removeEverything()
        pushToken = nil
        pushTokenSent = false
    }

    /// A6: back to setup as a fresh install, with new keys and a new `device_id` (SET-03).
    private func startOver() {
        identity = nil
        store = nil
        pairedDevice = nil
        link = LinkStatus(state: .idle(.notPaired))
        unreadThreads = 0
        received = nil
        unsentLocalContent = false
        clipboardNotice = nil
        clipboardConflict = nil
        relayNotice = nil
        clipboardEnabled = settings.clipboardEnabled
        sendImages = settings.sendImages
        autoClearSeconds = settings.autoClearSeconds
        relayEnabled = settings.relayEnabled
        smsEnabled = settings.smsEnabled
        smsNotify = settings.smsNotify
        smsPreview = settings.smsPreview
        selectedTab = .clipboard
        launch()
        didEraseAllData()
    }
}
