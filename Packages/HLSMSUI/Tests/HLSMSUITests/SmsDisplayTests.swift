import Foundation
import HLDesignSystem
import HLLocalization
import HLProtocol
import HLSMS
import HLSMSNotifications
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
        #expect(SmsDisplay.syncBanner(.failed(.storage)) == L10n.Error.smsSyncStorage)
        #expect(SmsDisplay.syncBanner(.done) == nil && SmsDisplay.syncBanner(.idle) == nil)
    }

    @Test("Bubble VoiceOver labels: sender and time received, You with time and status sent; the number in a group")
    func bubbleLabels() throws {
        let ts: Int64 = 1_727_150_000_000
        let time = SmsDisplay.bubbleTime(ts)
        let decoder = JSONDecoder()
        let thread = try decoder.decode(SmsThread.self, from: Data("""
            {"pair_id": "p", "thread_id": 7, "addresses_json": "[\\"+84900000123\\"]", "display_name": "Lan",
             "last_ts": \(ts), "unread_count": 0, "local_read_ts": 0}
            """.utf8))
        let received = try decoder.decode(SmsMessage.self, from: Data("""
            {"message_key": "sms:1", "thread_id": 7, "address": "+84900000123", "body": "Hi", "box": "inbox",
             "ts": \(ts), "read": true}
            """.utf8))
        #expect(SmsDisplay.bubbleAccessibility(received, thread: thread, status: nil)
            == L10n.A11y.smsBubbleReceived(sender: "Lan", time: time))
        var sent = received
        sent.box = SmsBox.sent.rawValue
        #expect(SmsDisplay.bubbleAccessibility(sent, thread: thread, status: .delivered)
            == L10n.A11y.smsBubbleSent(time: time, status: L10n.Sms.statusDelivered))
        var group = thread
        group.addressesJSON = #"["+84900000123","+84900000456"]"#
        #expect(SmsDisplay.bubbleAccessibility(received, thread: group, status: nil)
            == L10n.A11y.smsBubbleReceived(sender: PhoneNumberDisplay.format("+84900000123"), time: time))
    }

    @Test("The phone's SMS problem: off there, or READ_SMS/SEND_SMS missing with instructions; none when SMS works")
    func phoneProblem() {
        func capability(sms: Bool, missing: [String]) -> CapabilityData {
            CapabilityData(appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
                           features: Features(sms: SmsFeature(enabled: sms, canSend: true)), permissionsMissing: missing)
        }
        #expect(SmsPhoneProblem.of(nil, phoneName: "Pixel") == nil)
        #expect(SmsPhoneProblem.of(capability(sms: true, missing: ["READ_CONTACTS"]), phoneName: "Pixel") == nil)
        let off = SmsPhoneProblem.of(capability(sms: false, missing: []), phoneName: "Pixel của Lan")
        #expect(off == .offOnPhone(name: "Pixel của Lan") && off?.hasInstructions == false)
        #expect(off?.text == L10n.Pairing.reasonOffOnDevice(deviceName: "Pixel của Lan"))
        let missing = SmsPhoneProblem.of(capability(sms: true, missing: ["SEND_SMS"]), phoneName: "Pixel")
        #expect(missing == .missingPermission && missing?.hasInstructions == true)
        #expect(missing?.text == L10n.Pairing.reasonMissingSmsPermission)
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
