import Foundation
import HLAppCore
import HLProtocol
import HLTransport

extension CallLogEngine {
    /// Steps 3–6: `log_sync` from the stored cursor with `limit = 200`, one page per `ack`, until `has_more = false`.
    /// A sync without a cursor is a first sync for all its pages: its entries are seen already, so they do not raise
    /// the badge (no notification flood). Stops on a lost connection or a missing `ack` (E4), a missing permission
    /// (E2), a feature turned off (E1), a second provider error (E6) or a database error (E7).
    func sync(pairId: String) async {
        setStatus(.syncing)
        var cursor: String?
        do {
            cursor = try await store.cursor(pairId: pairId)
        } catch {
            return setStatus(.storage)
        }
        let firstSync = cursor == nil
        var retried = false
        while !Task.isCancelled {
            guard let peer, pairId == self.pairId else { return setStatus(.interrupted) }
            let ack: Ack
            do {
                ack = try await peer.request(.logSync, data: CallLogSyncRequest(cursor: cursor), id: HLUUID.v7(),
                                             timeout: requestTimeout)
            } catch {
                if !Task.isCancelled { setStatus(.interrupted) }
                return
            }
            guard ack.ok, let data = ack.data, let page = try? HLJSON.convert(data, to: CallLogSyncAckData.self) else {
                if ack.error?.code == .internal, !retried {
                    retried = true
                    try? await Task.sleep(for: providerRetryDelay)
                    continue
                }
                return setStatus(Self.status(after: ack.error?.code))
            }
            guard !Task.isCancelled, pairId == self.pairId else { return }
            do {
                try await store.writePage(page, pairId: pairId, firstSync: firstSync, now: now())
            } catch {
                return setStatus(.storage)
            }
            await publishBadge()
            cursor = page.cursor
            if !page.hasMore { return setStatus(.done) }
        }
    }

    /// Where a refused `log_sync` leaves the sync: E2 the permission, E1 the feature off on the phone, otherwise stopped
    /// until the next connection (E4, E6).
    static func status(after code: ErrorCode?) -> CallLogStatus {
        switch code {
        case .permissionMissing?: .permissionMissing
        case .featureDisabled?: .idle
        default: .interrupted
        }
    }

    /// Daily: entries older than 90 days go (CALL-04 Query).
    public func pruneOld() async {
        try? await store.deleteOlderThan(now() - CallLogStore.retentionMs)
        await publishBadge()
    }
}
