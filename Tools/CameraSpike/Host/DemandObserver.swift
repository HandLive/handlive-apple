import Foundation
import notify

/// Logs the Darwin notifications the extension posts when a consumer starts or stops the source stream
/// (CAM-02 API 1), to check that a sandboxed Camera Extension can signal demand to the app.
final class DemandObserver {
    static let shared = DemandObserver()
    private var tokens: [Int32] = []

    func start(log: SpikeEventLog) {
        guard tokens.isEmpty else { return }
        for name in [SpikeIdentifiers.demandNotification, SpikeIdentifiers.idleNotification] {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { _ in
                log.record("camera_demand", ["notification": name])
            }
            if status == NOTIFY_STATUS_OK { tokens.append(token) }
        }
    }
}
