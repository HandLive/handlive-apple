import Foundation
import HLProtocol
import Testing
@testable import HLAppCore

@Suite("Clipboard rules: QC3 card numbers, QC6 de-duplication, QC8 conflicts, what counts as a copy")
@MainActor
struct ClipboardRulesTests {
    @Test("QC3: Luhn-valid runs of 13–19 digits, single spaces or hyphens; long text is never checked")
    func cardNumbers() {
        #expect(SensitiveContent.looksLikeCardNumber("4111111111111111"))
        #expect(SensitiveContent.looksLikeCardNumber("4111 1111 1111 1111"))
        #expect(SensitiveContent.looksLikeCardNumber("Thẻ: 5500-0000-0000-0004, hết hạn 12/28"))
        #expect(SensitiveContent.looksLikeCardNumber("4222222222222"))
        #expect(SensitiveContent.looksLikeCardNumber("6011 0000 0000 0000 001"))
        #expect(!SensitiveContent.looksLikeCardNumber("4111 1111 1111 1112"))
        #expect(!SensitiveContent.looksLikeCardNumber("Order number: HL-240917-0042"))
        #expect(!SensitiveContent.looksLikeCardNumber("0912 345 678"))
        #expect(!SensitiveContent.looksLikeCardNumber("411111111117"))
        #expect(!SensitiveContent.looksLikeCardNumber("41111111111111111115"))
        #expect(!SensitiveContent.looksLikeCardNumber("4111  1111  1111  1111"))
        let long = "4111111111111111 " + String(repeating: "a", count: 250)
        #expect(!SensitiveContent.looksLikeCardNumber(long))
        #expect(SensitiveContent.looksLikeCardNumber(String(long.prefix(256))))
    }

    @Test("QC6: applied and ignored clips are duplicates for 10 minutes; rejected ones may come again; 256 kept")
    func ledger() {
        var ledger = ClipLedger(capacity: 3, window: 600)
        let start = Date(timeIntervalSince1970: 0)
        ledger.record("a", .applied, now: start)
        ledger.record("b", .ignored, now: start)
        ledger.record("c", .rejected, now: start)
        let appliedIsDuplicate = ledger.isDuplicate("a", now: start)
        let ignoredIsDuplicate = ledger.isDuplicate("b", now: start)
        let rejectedIsDuplicate = ledger.isDuplicate("c", now: start)
        #expect(appliedIsDuplicate && ignoredIsDuplicate && !rejectedIsDuplicate)
        ledger.record("d", .applied, now: start)
        let pushedOut = !ledger.isDuplicate("a", now: start) // over capacity
        let expired = !ledger.isDuplicate("b", now: start.addingTimeInterval(601))
        #expect(pushedOut && expired)
    }

    @Test("QC8: (a) a local change under 500 ms wins and is reported; (b) larger origin_ts, then larger device id")
    func conflicts() {
        let now = Date(timeIntervalSince1970: 100)
        let fresh = LocalChange(detectedAt: now.addingTimeInterval(-0.2), originTs: 99_800, originDeviceId: "b")
        #expect(ConflictPolicy.decide(originTs: 1, originDeviceId: "a", local: nil, now: now) == .write)
        #expect(ConflictPolicy.decide(originTs: 200_000, originDeviceId: "z", local: fresh, now: now) == .keepLocalAndReport)
        let old = LocalChange(detectedAt: now.addingTimeInterval(-3), originTs: 97_000, originDeviceId: "b")
        #expect(ConflictPolicy.decide(originTs: 98_000, originDeviceId: "a", local: old, now: now) == .write)
        #expect(ConflictPolicy.decide(originTs: 96_000, originDeviceId: "z", local: old, now: now) == .keepLocal)
        #expect(ConflictPolicy.decide(originTs: 97_000, originDeviceId: "c", local: old, now: now) == .write)
        #expect(ConflictPolicy.decide(originTs: 97_000, originDeviceId: "a", local: old, now: now) == .keepLocal)
    }

    @Test("CLIP-02 API 1: kind from the first text or image type; file URLs skip the item; own writes are marked")
    func reader() {
        let pasteboard = FakePasteboard()
        #expect(LocalClipReader.read(pasteboard) == .unsupported)
        pasteboard.copy([("public.html", Data("<b>x</b>".utf8)), (PasteboardTypeID.text, Data("x".utf8))])
        #expect(LocalClipReader.read(pasteboard) == .text("x", sensitiveType: false))
        pasteboard.copy([(PasteboardTypeID.fileURL, Data("file:///a".utf8)), (PasteboardTypeID.text, Data("a".utf8))])
        #expect(LocalClipReader.read(pasteboard) == .unsupported)
        pasteboard.copy([(PasteboardTypeID.tiff, Data([1])), (PasteboardTypeID.png, Data([2])),
                         (PasteboardTypeID.text, Data("name.png".utf8))])
        #expect(LocalClipReader.read(pasteboard) == .image(Data([2]), typeIdentifier: PasteboardTypeID.png,
                                                           sensitiveType: false))
        pasteboard.copy([(PasteboardTypeID.text, Data("secret".utf8)), ("org.nspasteboard.ConcealedType", Data())])
        #expect(LocalClipReader.read(pasteboard) == .text("secret", sensitiveType: true))
        pasteboard.copy([(PasteboardTypeID.text, Data("x".utf8)), (PasteboardTypeID.clipId, Data("id".utf8))])
        #expect(LocalClipReader.read(pasteboard) == .ownWrite(clipId: "id"))
    }
}
