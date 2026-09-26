import Foundation
import HLProtocol

extension SmsEngine {
    // MARK: - SMS-03 steps 8–11

    /// Older messages from the phone, 50 at a time, one request per conversation at a time. Without a session the
    /// request waits for the next connection (E2).
    public func loadOlder(threadId: Int64) {
        guard let pairId, !historyComplete.contains(threadId), !historyLoading.contains(threadId) else {
            if historyComplete.contains(threadId) { onEvent(.history(threadId: threadId, .complete)) }
            return
        }
        guard let peer = phone?.peer, isActive else {
            if phone != nil {
                onEvent(.history(threadId: threadId, .unavailable(inactiveProblem)))
            } else {
                historyWanted.insert(threadId)
                onEvent(.history(threadId: threadId, .needsConnection))
            }
            return
        }
        historyLoading.insert(threadId)
        onEvent(.history(threadId: threadId, .loading))
        Task {
            let state = await fetchHistory(peer: peer, pairId: pairId, threadId: threadId)
            historyLoading.remove(threadId)
            onEvent(.history(threadId: threadId, state))
        }
    }

    /// Whether the phone may still have older messages than the stored ones.
    public func mayHaveOlder(threadId: Int64) -> Bool {
        !historyComplete.contains(threadId)
    }

    private var inactiveProblem: SmsProblem {
        if case .failed(let problem) = inactiveStatus { return problem }
        return .featureOff
    }

    private func fetchHistory(peer: any SmsPeer, pairId: String, threadId: Int64) async -> SmsHistoryState {
        let before = ((try? await store.oldestTimestamp(pairId: pairId, threadId: threadId)) ?? nil) ?? now()
        let request = SmsHistoryRequest(threadId: threadId, beforeTs: before)
        guard let ack = try? await peer.request(.history, data: request, id: HLUUID.v7(), timeout: requestTimeout) else {
            return .failed // E4 (TIMEOUT or lost session)
        }
        guard ack.ok, let data = ack.data, let page = try? HLJSON.convert(data, to: SmsHistoryAckData.self) else {
            switch ack.error?.code {
            case .smsThreadNotFound?:
                historyComplete.insert(threadId) // E3 is remembered as "no more messages"
                return .threadGone
            case .featureDisabled?: return .unavailable(.featureOff)
            case .permissionMissing?: return .unavailable(.permissionMissing)
            default: return .failed
            }
        }
        guard (try? await store.insertHistory(page.messages, pairId: pairId)) != nil else { return .failed }
        if !page.hasMore {
            historyComplete.insert(threadId)
            return .complete
        }
        return .ready
    }
}
