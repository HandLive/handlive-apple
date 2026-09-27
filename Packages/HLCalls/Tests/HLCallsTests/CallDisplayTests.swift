import Foundation
import HLLocalization
import HLProtocol
import Testing
@testable import HLCallsUI

/// The texts of the call screens: the timer, durations, times, symbols and what VoiceOver reads.
@Suite("Call display texts")
struct CallDisplayTests {
    @Test("Timer mm:ss, with hours past an hour; a call of 0 s has no duration")
    func timer() {
        #expect(CallDisplay.timer(135) == "02:15")
        #expect(CallDisplay.timer(0) == "00:00")
        #expect(CallDisplay.timer(3725).hasSuffix("02:05"))
        #expect(CallDisplay.duration(0) == nil)
        #expect(CallDisplay.duration(125)?.isEmpty == false)
    }

    @Test("Today shows the time, an older call its date")
    func listTime() throws {
        let now = Date(timeIntervalSince1970: 1_727_150_400)
        let today = Int64(now.timeIntervalSince1970 * 1000) - 60_000
        #expect(CallDisplay.listTime(today, now: now)
            == Date(timeIntervalSince1970: TimeInterval(today) / 1000).formatted(date: .omitted, time: .shortened))
        let older = Int64(now.timeIntervalSince1970 * 1000) - 5 * 86_400_000
        #expect(CallDisplay.listTime(older, now: now) != CallDisplay.listTime(today, now: now))
    }

    @Test("Missed calls say so to VoiceOver; the SIM label and duration follow the time; no number is No Caller ID")
    func accessibility() async throws {
        let store = try CallLogFixtures.store()
        let pairId = CallLogFixtures.pairId
        try await store.writePage(CallLogFixtures.page([
            CallLogFixtures.entry(1, .missed, name: "Nguyễn Văn A"),
            CallLogFixtures.entry(2, .outgoing, number: nil, duration: 125),
        ], cursor: "c"), pairId: pairId, firstSync: true, now: 1)
        let entries = try await store.entries(pairId: pairId)
        let missed = try #require(entries.first { $0.entryId == 1 })
        let label = CallDisplay.accessibilityLabel(missed, simLabel: "SIM 1")
        #expect(label.hasPrefix("Nguyễn Văn A, " + L10n.Call.typeMissed) && label.hasSuffix("SIM 1"))
        #expect(CallDisplay.typeLabel(.rejected) == L10n.Call.typeRejected && CallDisplay.typeLabel(.unrecognized) == nil)
        let outgoing = try #require(entries.first { $0.entryId == 2 })
        #expect(CallDisplay.title(outgoing) == L10n.Call.noCallerId)
        #expect(CallDisplay.details(outgoing, simLabel: nil) == [CallDisplay.duration(125)].compactMap { $0 })
        #expect(CallDisplay.symbol(.missed) == "phone.arrow.down.left" && CallDisplay.symbol(.outgoing) == "phone.arrow.up.right")
    }
}
