import Foundation
import HLTransport
import UserNotifications

/// Notification permission (SET-03 API 4): asked once; afterwards only read.
public enum NotificationPermission: Equatable, Sendable {
    case notDetermined, allowed, denied

    public static func current() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    /// `requestAuthorization([.alert, .sound, .badge])`; no provisional, no critical alerts.
    public static func request() async -> NotificationPermission {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await current()
    }
}

/// SET-03 API 5: browse `_handlive._tcp` so the system shows the local network prompt (iOS, macOS 15+). A phone in
/// the results means allowed, `PolicyDenied` means denied; with neither after `settle`, the answer is taken as allowed
/// and a later denial still shows up as a connection issue (CONN-01 E8).
public enum LocalNetworkProbe {
    @Sendable public static func run() async -> DiscoveryState {
        await probe(settle: .seconds(8))
    }

    static func probe(settle: Duration) async -> DiscoveryState {
        await withTaskGroup(of: DiscoveryState?.self) { group in
            group.addTask {
                for await event in BonjourDiscovery().events() {
                    switch event {
                    case .state(.localNetworkDenied): return .localNetworkDenied
                    case .results(let phones) where !phones.isEmpty: return .ready
                    default: continue
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: settle)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll() // ends the browse (the stream stops the browser when iteration ends)
            return first ?? .ready
        }
    }
}
