import Foundation
import HLCrypto
import HLProtocol

/// Directional keys of a `/v1/ctl` session (0.6.3): seals with `k_c2s`, opens with `k_s2c`, keeps the
/// previous `k_s2c` for `REKEY` grace after a key change, counts envelopes and age for `REKEY_AFTER`.
struct SessionCipher {
    private(set) var keys: SessionKeys
    private(set) var epoch: Int32 = 0
    private(set) var sentCount = 0
    private(set) var receivedCount = 0
    private(set) var epochStart: ContinuousClock.Instant
    private var previousReceiveKey: (key: Data, until: ContinuousClock.Instant)?

    init(keys: SessionKeys, now: ContinuousClock.Instant) {
        self.keys = keys
        epochStart = now
    }

    mutating func seal(type: MessageType, plaintext: Data, id: String = HLUUID.v7()) throws -> Envelope {
        let envelope = try EnvelopeCipher.seal(type: type, plaintext: plaintext, key: keys.clientToServer, id: id)
        sentCount += 1
        return envelope
    }

    /// Opens with the current key, then with the previous one while its grace lasts.
    mutating func open(_ envelope: Envelope, now: ContinuousClock.Instant) throws -> Data {
        do {
            let plaintext = try EnvelopeCipher.open(envelope, key: keys.serverToClient)
            receivedCount += 1
            return plaintext
        } catch {
            guard let previous = previousReceiveKey, now < previous.until else { throw error }
            let plaintext = try EnvelopeCipher.open(envelope, key: previous.key)
            receivedCount += 1
            return plaintext
        }
    }

    /// Switches to the keys of `epoch`; the old receive key stays usable for `grace`.
    mutating func install(_ newKeys: SessionKeys, epoch: Int32, now: ContinuousClock.Instant, grace: Duration) {
        previousReceiveKey = (keys.serverToClient, now.advanced(by: grace))
        keys = newKeys
        self.epoch = epoch
        sentCount = 0
        receivedCount = 0
        epochStart = now
    }

    func needsRekey(now: ContinuousClock.Instant, maxEnvelopes: Int, maxAge: Duration) -> Bool {
        sentCount >= maxEnvelopes || receivedCount >= maxEnvelopes || epochStart.duration(to: now) >= maxAge
    }
}

/// `DEDUP_WINDOW` (0.5.1 rule 2): every envelope `id` accepted in the current key epoch and the `ack` answered to
/// each request, so a repeated request gets the same `ack` without being processed again. The set is emptied at
/// rekey; the previous epoch's ids stay while its keys are still accepted. `REKEY_AFTER` (10,000 envelopes per
/// direction) bounds it, so nothing is evicted inside an epoch: an evicted id could be replayed. A set that reaches
/// `limit` (20,000) because the rekey has not completed is full: the session closes with 4410. The kept acks are
/// bounded to `ackBudget` bytes (8 MiB) for both epochs, oldest dropped first; a duplicate whose ack was dropped is
/// still a duplicate, only without an answer.
struct RecentEnvelopeIDs {
    static let defaultLimit = 20_000
    static let defaultAckBudget = 8 * 1024 * 1024

    let limit: Int
    let ackBudget: Int
    private var current: [String: String?] = [:]
    private var previous: (ids: [String: String?], until: ContinuousClock.Instant)?
    /// UTF-8 bytes of every kept ack.
    private(set) var keptAckBytes = 0
    /// Ids whose ack is kept, oldest first.
    private var ackOrder: [String] = []

    enum Lookup: Equatable {
        case new
        case duplicate(ackWire: String?)
    }

    init(limit: Int = RecentEnvelopeIDs.defaultLimit, ackBudget: Int = RecentEnvelopeIDs.defaultAckBudget) {
        self.limit = limit
        self.ackBudget = ackBudget
    }

    /// Ids accepted in the current epoch.
    var count: Int { current.count }
    var isEmpty: Bool { current.isEmpty }
    var isFull: Bool { current.count >= limit }

    /// Reports whether `id` was already accepted; records nothing (a forged envelope must not take an id).
    mutating func lookup(_ id: String, now: ContinuousClock.Instant) -> Lookup {
        if let ack = current[id] { return .duplicate(ackWire: ack) }
        guard let kept = previous else { return .new }
        guard now < kept.until else {
            dropPrevious()
            return .new
        }
        if let ack = kept.ids[id] { return .duplicate(ackWire: ack) }
        return .new
    }

    /// Records `id` once its envelope decrypted.
    mutating func record(_ id: String) {
        if current[id] == nil { current[id] = .some(nil) }
    }

    /// Remembers the `ack` sent for a request, then drops the oldest acks beyond `ackBudget`.
    mutating func remember(ackWire: String, for id: String) {
        guard current[id] != nil || previous?.ids[id] != nil else { return }
        if forgetAck(of: id) { ackOrder.removeAll { $0 == id } } // a second ack for the same request replaces it
        if current[id] != nil {
            current[id] = .some(ackWire)
        } else {
            previous?.ids[id] = .some(ackWire)
        }
        keptAckBytes += ackWire.utf8.count
        ackOrder.append(id)
        while keptAckBytes > ackBudget, !ackOrder.isEmpty {
            forgetAck(of: ackOrder.removeFirst())
        }
    }

    /// New key epoch: the ids so far stay duplicates for as long as the old keys are accepted.
    mutating func startEpoch(now: ContinuousClock.Instant, previousKeptFor grace: Duration) {
        dropPrevious()
        previous = (current, now.advanced(by: grace))
        current = [:]
    }

    /// Drops the ack kept for `id` (the id itself stays), wherever it is. Returns whether one was kept.
    @discardableResult
    private mutating func forgetAck(of id: String) -> Bool {
        if case .some(.some(let ack)) = current[id] {
            current[id] = .some(nil)
            keptAckBytes -= ack.utf8.count
            return true
        } else if case .some(.some(let ack)) = previous?.ids[id] {
            previous?.ids[id] = .some(nil)
            keptAckBytes -= ack.utf8.count
            return true
        }
        return false
    }

    private mutating func dropPrevious() {
        guard let old = previous else { return }
        previous = nil
        for case .some(let ack) in old.ids.values { keptAckBytes -= ack.utf8.count }
        ackOrder.removeAll { old.ids[$0] != nil }
    }
}
