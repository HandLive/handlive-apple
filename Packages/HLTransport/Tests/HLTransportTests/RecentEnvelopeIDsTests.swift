import Foundation
import Testing
@testable import HLTransport

@Suite("DEDUP_WINDOW: every id accepted in the key epoch (0.5.1 rule 2)")
struct RecentEnvelopeIDsTests {
    private let start = ContinuousClock.now

    @Test("An id stays a duplicate for the whole epoch, however old it is")
    func keptForTheEpoch() {
        var ids = RecentEnvelopeIDs()
        ids.record("a")
        ids.remember(ackWire: "ack-a", for: "a")
        #expect(ids.lookup("a", now: start.advanced(by: .seconds(23 * 3600))) == .duplicate(ackWire: "ack-a"))
    }

    @Test("More than 1,000 ids in one epoch: the first one is still a duplicate")
    func noEvictionWithinTheEpoch() {
        var ids = RecentEnvelopeIDs()
        for index in 0..<10_000 { ids.record("id-\(index)") }
        #expect(ids.lookup("id-0", now: start) == .duplicate(ackWire: nil))
        #expect(ids.count == 10_000)
    }

    @Test("A lookup does not record: only a decrypted envelope takes its id")
    func lookupDoesNotRecord() {
        var ids = RecentEnvelopeIDs()
        #expect(ids.lookup("forged", now: start) == .new)
        #expect(ids.lookup("forged", now: start) == .new)
        ids.record("forged")
        #expect(ids.lookup("forged", now: start) == .duplicate(ackWire: nil))
    }

    @Test("Rekey empties the set; the previous epoch's ids last while its keys are accepted")
    func rekeyKeepsThePreviousEpochDuringGrace() {
        var ids = RecentEnvelopeIDs()
        ids.record("old")
        ids.remember(ackWire: "ack-old", for: "old")
        ids.startEpoch(now: start, previousKeptFor: .seconds(30))
        #expect(ids.isEmpty)
        #expect(ids.lookup("old", now: start.advanced(by: .seconds(29))) == .duplicate(ackWire: "ack-old"))
        ids.record("new")
        #expect(ids.lookup("old", now: start.advanced(by: .seconds(31))) == .new)
        #expect(ids.lookup("new", now: start.advanced(by: .seconds(31))) == .duplicate(ackWire: nil))
    }

    @Test("A second rekey drops the epoch before the previous one")
    func secondRekey() {
        var ids = RecentEnvelopeIDs()
        ids.record("epoch0")
        ids.startEpoch(now: start, previousKeptFor: .seconds(30))
        ids.record("epoch1")
        ids.startEpoch(now: start.advanced(by: .seconds(1)), previousKeptFor: .seconds(30))
        #expect(ids.lookup("epoch0", now: start.advanced(by: .seconds(2))) == .new)
        #expect(ids.lookup("epoch1", now: start.advanced(by: .seconds(2))) == .duplicate(ackWire: nil))
    }
}
