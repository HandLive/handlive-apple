import Foundation
import HLProtocol

extension SmsEngine {
    // MARK: - SMS-01

    /// Starts SMS-01 unless a sync of the pair runs already (step 1).
    func startSync() {
        guard syncTask == nil, isActive, pairId != nil else { return }
        syncTask = Task { [weak self] in
            await self?.runSync()
            self?.syncTask = nil
        }
    }

    /// "Resync All SMS" (A1–A2): forget the synced messages, keep the waiting ones, and download everything again.
    public func resyncAll() async {
        guard let pairId, isActive else { return }
        syncTask?.cancel()
        _ = await syncTask?.value
        guard (try? await store.resetForResync(pairId: pairId)) != nil else { return setSyncStatus(.failed(.storage)) }
        historyComplete.removeAll()
        await publishBadge()
        startSync()
    }

    /// Steps 3–9: pages of `sms/sync` until `has_more = false`; each page in one transaction, the cursor only at the end.
    func runSync() async {
        guard let pairId, let peer = phone?.peer else { return }
        var cursor = try? await store.cursor(pairId: pairId)
        var pageToken: String?
        var downloaded = 0
        var recoveries = SyncRecoveries()
        setSyncStatus(.syncing(downloaded: 0, firstSync: cursor == nil))
        while !Task.isCancelled {
            let request = SmsSyncRequest(cursor: cursor, pageToken: pageToken)
            let ack: Ack
            do {
                ack = try await peer.request(.sync, data: request, id: HLUUID.v7(), timeout: requestTimeout)
            } catch {
                return setSyncStatus(.failed(.interrupted)) // E4: the pages written stay, the old cursor too
            }
            guard ack.ok, let data = ack.data, let page = try? HLJSON.convert(data, to: SmsSyncAckData.self) else {
                guard case .restart(let from) = await recover(from: ack.error, recoveries: &recoveries, pairId: pairId)
                else { return }
                (cursor, pageToken) = (from, nil)
                continue
            }
            guard (try? await store.applySyncPage(page, pairId: pairId, now: now())) != nil else {
                return setSyncStatus(.failed(.storage)) // E7: the transaction was rolled back
            }
            downloaded += page.messages.count
            if page.hasMore, let token = page.pageToken {
                pageToken = token
                setSyncStatus(.syncing(downloaded: downloaded, firstSync: cursor == nil))
                continue
            }
            await finishSync(unread: page.unread ?? [], pairId: pairId)
            return
        }
    }

    /// Step 9 after the last page: notifications of what the phone has read go away, the badge follows.
    private func finishSync(unread: [SmsReadState], pairId: String) async {
        setSyncStatus(.done)
        let unreadIds = Set(unread.map(\.threadId))
        let threads = (try? await store.threads(pairId: pairId, limit: Int.max)) ?? []
        for thread in threads where !unreadIds.contains(thread.threadId) {
            onEvent(.removeNotifications(pairId: pairId, threadId: thread.threadId, upToTs: nil))
        }
        for state in unread {
            onEvent(.removeNotifications(pairId: pairId, threadId: state.threadId, upToTs: state.readUpToTs))
        }
        onEvent(.removeGenericNotifications)
        await publishBadge()
    }

    struct SyncRecoveries {
        var pageToken = false
        var cursor = false
        var providerError = false
    }

    enum SyncNext {
        /// Loop again from this cursor (`nil` = first sync).
        case restart(from: String?)
        case stop
    }

    /// What an error `ack` means for the loop (E1, E2, E5, E6); `.stop` has set the status.
    private func recover(from error: AckError?, recoveries: inout SyncRecoveries, pairId: String) async -> SyncNext {
        switch error?.code {
        case .smsCursorInvalid?:
            let reason = error?.details.flatMap { try? HLJSON.convert($0, to: CursorInvalidDetails.self) }?.reason
            if reason == "page_token" && !recoveries.pageToken {
                recoveries.pageToken = true
                return .restart(from: try? await store.cursor(pairId: pairId)) // start over from the stored cursor
            }
            guard !recoveries.cursor, (try? await store.resetForResync(pairId: pairId)) != nil else { break }
            recoveries.cursor = true // the cursor is stale: automatic "Resync All SMS" (A2)
            historyComplete.removeAll()
            return .restart(from: nil)
        case .featureDisabled?:
            setSyncStatus(.failed(.featureOff))
            return .stop
        case .permissionMissing?:
            setSyncStatus(.failed(.permissionMissing))
            return .stop
        case .internal? where !recoveries.providerError:
            recoveries.providerError = true
            try? await Task.sleep(for: providerRetryDelay)
            guard !Task.isCancelled else { return .stop }
            return .restart(from: try? await store.cursor(pairId: pairId))
        default:
            break
        }
        setSyncStatus(.failed(error?.code == .internal ? .phoneError : .interrupted))
        return .stop
    }
}

/// `details` of `SMS_CURSOR_INVALID`: `reason` is `cursor` or `page_token` (0.8.1).
struct CursorInvalidDetails: Decodable {
    let reason: String?
}
