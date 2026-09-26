import Foundation
import HLDesignSystem
import HLLocalization
import HLProtocol
import HLSMS
import Testing
@testable import HLSMSUI

/// Texts of the Messages screens from the catalog: counter (SMS-04 field 3), failure reasons (field 8), sync banner
/// (SMS-01 field 1), times (SMS-03 fields 4, 7).
@Suite("SMS display texts")
struct SmsDisplayTests {
    @Test("Counter: 0/160 empty, then used/limit · parts with the limit of the current number of parts")
    func counter() {
        #expect(SmsDisplay.counter(for: "") == L10n.Sms.charCount(used: "0", limit: "160"))
        #expect(SmsDisplay.counter(for: String(repeating: "a", count: 120))
                == L10n.Sms.charCounter(used: "120", limit: "160", parts: L10n.Sms.partCount(count: 1)))
        #expect(SmsDisplay.counter(for: String(repeating: "a", count: 230))
                == L10n.Sms.charCounter(used: "230", limit: "306", parts: L10n.Sms.partCount(count: 2)))
        #expect(SmsDisplay.counter(for: "Chiều nay").contains("/70"))
    }

    @Test("Failure reasons by error code; anything else is Couldn't send")
    func reasons() {
        #expect(SmsDisplay.failureReason(.smsNoService) == L10n.Error.smsNoService)
        #expect(SmsDisplay.failureReason(.notConnected) == L10n.Error.smsNotConnected)
        #expect(SmsDisplay.failureReason(.smsSimUnavailable) == L10n.Error.smsSimUnavailable)
        #expect(SmsDisplay.failureReason(.internal) == L10n.Error.smsGenericFailure)
        #expect(SmsDisplay.bubbleStatus(.failed, error: .smsRadioOff) == .failed(reason: L10n.Error.smsRadioOff))
    }

    @Test("Sync banner: syncing, the first sync's count, failed; nothing when done")
    func banner() {
        #expect(SmsDisplay.syncBanner(.syncing(downloaded: 0, firstSync: true)) == L10n.Sms.syncing)
        #expect(SmsDisplay.syncBanner(.syncing(downloaded: 1500, firstSync: true)) == L10n.Sms.syncDownloaded(count: 1500))
        #expect(SmsDisplay.syncBanner(.failed(.interrupted)) == L10n.Sms.syncFailed)
        #expect(SmsDisplay.syncBanner(.done) == nil && SmsDisplay.syncBanner(.idle) == nil)
    }

    @Test("List time: today's time, a day marker for yesterday, the date otherwise")
    func times() {
        let now = Date(timeIntervalSince1970: 1_727_150_000)
        let today = Int64(now.timeIntervalSince1970 * 1000) - 60_000
        #expect(SmsDisplay.listTime(today, now: now) == Date(timeIntervalSince1970: TimeInterval(today) / 1000)
            .formatted(date: .omitted, time: .shortened))
        let lastYear = Int64(now.timeIntervalSince1970 * 1000) - 400 * 86_400_000
        #expect(!SmsDisplay.listTime(lastYear, now: now).isEmpty)
    }
}
