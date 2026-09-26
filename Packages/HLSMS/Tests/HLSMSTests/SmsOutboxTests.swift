import Foundation
import HLProtocol
import Testing
@testable import HLSMS

/// SMS-04: the outbox and its forward-only status rule (API 2 logic 2), expiry and "Try Again"; the part counter of
/// field 3.
@Suite("SMS outbox and part counter")
struct SmsOutboxTests {
    let pairId = SmsFixtures.pairId
    let localId = "0192f3e2-4b5c-7d6e-9f70-8a9b0c1d2e3f"

    struct Step: Sendable, CustomTestStringConvertible {
        let from: SmsSendState
        let to: SmsSendState
        let allowed: Bool
        var testDescription: String { "\(from) → \(to): \(allowed)" }
    }

    static let steps: [Step] = SmsSendState.allCases.flatMap { from in
        SmsSendState.allCases.map { to in
            let allowed = switch (from, to) {
            case (.pending, .sending), (.pending, .sent), (.pending, .delivered), (.pending, .failed),
                 (.sending, .sent), (.sending, .delivered), (.sending, .failed), (.sent, .delivered): true
            default: false
            }
            return Step(from: from, to: to, allowed: allowed)
        }
    }

    @Test("Status moves only forward; duplicates and backward steps are ignored", arguments: steps)
    func forwardOnly(_ step: Step) async throws {
        #expect(step.from.allows(step.to) == step.allowed)
        let store = SmsStore(database: try SmsFixtures.database())
        try await store.enqueue(SmsDraft(localId: localId,
                                         threadId: 1, addresses: ["+1"], body: "x", subId: nil),
                                pairId: pairId, now: 1)
        if step.from != .pending { try await store.transition(localId: localId, to: step.from, now: 2) }
        #expect(try await store.outboxEntry(localId: localId)?.state == step.from)
        let changed = try await store.transition(localId: localId, to: step.to, error: nil, now: 3)
        #expect(changed == step.allowed)
        #expect(try await store.outboxEntry(localId: localId)?.state == (step.allowed ? step.to : step.from))
    }

    @Test("24 h waiting → failed NOT_CONNECTED; completed entries leave after 30 days; Try Again drops the failed row")
    func expiryAndRetry() async throws {
        let store = SmsStore(database: try SmsFixtures.database())
        let day: Int64 = 86_400_000
        try await store.enqueue(SmsDraft(localId: localId,
                                         threadId: 1, addresses: ["+1"], body: "old",
                                         subId: 2), pairId: pairId, now: 0)
        try await store.enqueue(SmsDraft(localId: "0192f3e2-0000-7000-8000-000000000009",
                                         threadId: 1, addresses: ["+1"], body: "done",
                                         subId: nil), pairId: pairId, now: 0)
        try await store.transition(localId: "0192f3e2-0000-7000-8000-000000000009", to: .delivered, now: 1)
        try await store.recordAttempt(localId: localId, now: 2)
        try await store.expireOutbox(now: day + 1)
        let expired = try #require(try await store.outboxEntry(localId: localId))
        #expect(expired.state == .failed && expired.errorCode == .notConnected && expired.attempts == 1)
        #expect(try await store.pendingCount(pairId: pairId) == 0)
        try await store.expireOutbox(now: 31 * day)
        #expect(try await store.outboxEntry(localId: "0192f3e2-0000-7000-8000-000000000009") == nil)
        let removed = try await store.removeFailed(localId: localId)
        #expect(removed?.body == "old" && removed?.subId == 2)
        #expect(try await store.outboxEntry(localId: localId) == nil)
    }

    @Test("GSM-7: 160 in one part, 153 per part beyond; the extension table counts twice")
    func gsm7() {
        #expect(SmsPartCounter.estimate("") == SmsPartEstimate(encoding: .gsm7, units: 0, parts: 0, capacity: 160))
        let short = SmsPartCounter.estimate(String(repeating: "a", count: 120))
        #expect(short == SmsPartEstimate(encoding: .gsm7, units: 120, parts: 1, capacity: 160))
        #expect(SmsPartCounter.estimate(String(repeating: "a", count: 160)).parts == 1)
        let two = SmsPartCounter.estimate(String(repeating: "a", count: 161))
        #expect(two == SmsPartEstimate(encoding: .gsm7, units: 161, parts: 2, capacity: 306))
        #expect(SmsPartCounter.estimate("€[]").units == 6)
        #expect(SmsPartCounter.estimate("Ok, 3h @ phòng").encoding == .gsm7) // ò is in the GSM-7 alphabet
        #expect(SmsPartCounter.estimate("Ok, 3h @ phòng họp").encoding == .ucs2) // ọ is not
        #expect(SmsPartCounter.estimate("Hello ÄÖÜ ñ à").encoding == .gsm7)
    }

    @Test("UCS-2 as soon as one character is outside GSM-7: 70, then 67 per part; emoji take two units")
    func ucs2() {
        let vietnamese = SmsPartCounter.estimate("Chiều nay 3h họp nhé")
        #expect(vietnamese == SmsPartEstimate(encoding: .ucs2, units: 20, parts: 1, capacity: 70))
        #expect(SmsPartCounter.estimate(String(repeating: "ệ", count: 71))
                == SmsPartEstimate(encoding: .ucs2, units: 71, parts: 2, capacity: 134))
        #expect(SmsPartCounter.estimate("ok 👍").units == 5)
    }

    @Test("Text and recipient checks of step 2")
    func validation() {
        #expect(SmsEngine.validText("   ") == nil)
        #expect(SmsEngine.validText("  hi \n") == "hi")
        #expect(SmsEngine.validText(String(repeating: "ệ", count: 1600)) != nil)
        #expect(SmsEngine.validText(String(repeating: "ệ", count: 1601)) == nil)
        #expect(SmsEngine.validRecipient("+84 900 000 123") == "+84900000123")
        #expect(SmsEngine.validRecipient("8088") == "8088")
        #expect(SmsEngine.validRecipient("12") == nil)
        #expect(SmsEngine.validRecipient("+1234567890123456") == nil)
        #expect(SmsEngine.validRecipient("VIETTEL") == nil)
    }
}
