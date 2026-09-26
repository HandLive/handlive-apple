import Foundation

/// Outcomes of the `clip_id`s already processed (QC6): the latest 256 for 10 minutes. A rejected clip may be accepted
/// again (a resend after `CLIP_CHECKSUM_MISMATCH` keeps its `clip_id`).
struct ClipLedger {
    enum Outcome: Equatable {
        case applied, ignored, rejected
    }

    private struct Entry {
        let clipId: String
        var outcome: Outcome
        var at: Date
    }

    private var entries: [Entry] = []
    private let capacity: Int
    private let window: TimeInterval

    init(capacity: Int = ClipboardConstants.ledgerCapacity, window: TimeInterval = ClipboardConstants.ledgerWindow) {
        self.capacity = capacity
        self.window = window
    }

    /// `applied` or `ignored` → the push is a duplicate; `rejected` or unknown → process it.
    mutating func isDuplicate(_ clipId: String, now: Date) -> Bool {
        entries.removeAll { now.timeIntervalSince($0.at) > window }
        guard let entry = entries.first(where: { $0.clipId == clipId }) else { return false }
        return entry.outcome != .rejected
    }

    mutating func record(_ clipId: String, _ outcome: Outcome, now: Date) {
        entries.removeAll { $0.clipId == clipId || now.timeIntervalSince($0.at) > window }
        entries.append(Entry(clipId: clipId, outcome: outcome, at: now))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
