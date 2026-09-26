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

    mutating func seal(type: MessageType, plaintext: Data) throws -> Envelope {
        let envelope = try EnvelopeCipher.seal(type: type, plaintext: plaintext, key: keys.clientToServer)
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

/// `DEDUP_WINDOW` (0.5.1 rule 2): ids handled in the last 5 minutes (at most 1 000) and the `ack` answered to
/// each request, so a repeated request gets the same `ack` without being processed again.
struct RecentEnvelopeIDs {
    private let window: Duration
    private let capacity: Int
    private var order: [String] = []
    private var entries: [String: (at: ContinuousClock.Instant, ack: String?)] = [:]

    init(window: Duration, capacity: Int) {
        self.window = window
        self.capacity = capacity
    }

    enum Lookup: Equatable {
        case new
        case duplicate(ackWire: String?)
    }

    /// Records `id` when new; reports a duplicate otherwise.
    mutating func check(_ id: String, now: ContinuousClock.Instant) -> Lookup {
        purge(now: now)
        if let entry = entries[id] { return .duplicate(ackWire: entry.ack) }
        entries[id] = (now, nil)
        order.append(id)
        if order.count > capacity { entries[order.removeFirst()] = nil }
        return .new
    }

    /// Remembers the `ack` sent for a request.
    mutating func remember(ackWire: String, for id: String) {
        if let entry = entries[id] { entries[id] = (entry.at, ackWire) }
    }

    private mutating func purge(now: ContinuousClock.Instant) {
        while let first = order.first, let entry = entries[first], entry.at.duration(to: now) > window {
            entries[first] = nil
            order.removeFirst()
        }
    }
}
