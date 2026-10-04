import Foundation
import Testing
@testable import HLLocalization

@Suite("Relative time of the last sync")
struct RelativeTimeTests {
    let now = Date(timeIntervalSince1970: 1_727_150_300)
    let english = Locale(identifier: "en_US")

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    @Test("A sync that just finished reads now, never \"in 0 seconds\"")
    func justFinishedReadsNow() {
        #expect(HLRelativeTime.past(milliseconds: ms(now.addingTimeInterval(-0.5)), now: now, locale: english) == "now")
        #expect(HLRelativeTime.past(milliseconds: ms(now), now: now, locale: english) == "now")
    }

    @Test("A moment in the future reads now too")
    func futureReadsNow() {
        let ahead = ms(now.addingTimeInterval(0.4))
        #expect(HLRelativeTime.past(milliseconds: ahead, now: now, locale: english) == "now")
        #expect(HLRelativeTime.past(milliseconds: ms(now.addingTimeInterval(30)), now: now, locale: english) == "now")
    }

    @Test("Under a minute reads now; older moments count back in minutes, hours, days")
    func pastCountsBack() {
        #expect(HLRelativeTime.past(milliseconds: ms(now.addingTimeInterval(-20)), now: now, locale: english) == "now")
        #expect(HLRelativeTime.past(milliseconds: ms(now.addingTimeInterval(-300)), now: now, locale: english)
            == "5 minutes ago")
        #expect(HLRelativeTime.past(milliseconds: ms(now.addingTimeInterval(-7_200)), now: now, locale: english)
            == "2 hours ago")
    }

    @Test("Vietnamese reads the same way")
    func vietnamese() {
        let vi = Locale(identifier: "vi_VN")
        let ahead = HLRelativeTime.past(milliseconds: ms(now.addingTimeInterval(1)), now: now, locale: vi)
        let justNow = HLRelativeTime.past(milliseconds: ms(now), now: now, locale: vi)
        #expect(ahead == justNow && !ahead.contains("sau") && !ahead.contains("0"))
        #expect(HLRelativeTime.past(milliseconds: ms(now.addingTimeInterval(-300)), now: now, locale: vi).contains("5"))
    }
}
