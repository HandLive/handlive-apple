import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLAppCore

/// CLIP-02 (Mac → phone) and the sending half of CLIP-03.
@Suite("Clipboard: sending from the Mac")
@MainActor
struct ClipboardSendTests {
    @Test("No content is read while changeCount is unchanged; a copy goes out inline with source mac")
    func pollsWithoutReading() async {
        let harness = ClipboardHarness()
        let reads = harness.pasteboard.contentReads
        harness.engine.poll()
        harness.engine.poll()
        #expect(harness.pasteboard.contentReads == reads && harness.peer.pushes.isEmpty)
        harness.pasteboard.copy(text: "https://example.com/docs/q3-report")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        let push = harness.peer.pushes[0]
        #expect(push.text == "https://example.com/docs/q3-report" && push.source == .mac && !push.sensitive)
        #expect(push.originDeviceId == ClipboardHarness.macId && push.transfer == nil && push.kind == .text)
        #expect(push.originTs == 1_727_150_000_000 && HLUUID.isValid(push.clipId, version: 7))
    }

    @Test("Manual send: 'Sent to' after the ack; not connected → will send within 2 minutes (E6), then replayed")
    func manualSend() async {
        let harness = ClipboardHarness(connected: false)
        harness.pasteboard.copy(text: "hello")
        harness.engine.sendClipboardNow()
        #expect(harness.notices == [.notConnectedWillSend] && harness.peer.pushes.isEmpty)
        harness.advance(60)
        harness.connect()
        #expect(await harness.until { harness.peer.pushes.count == 1 }) // QC7 replay on connect
        #expect(harness.peer.pushes[0].text == "hello")
        harness.pasteboard.copy(text: "again")
        harness.engine.sendClipboardNow()
        #expect(await harness.until { harness.notices.last == .sent(deviceName: "Pixel của Lan") })
    }

    @Test("QC7: a clip older than 120 s or already acknowledged is not replayed")
    func replayWindow() async {
        let harness = ClipboardHarness(connected: false)
        harness.pasteboard.copy(text: "old")
        harness.engine.poll()
        harness.advance(121)
        harness.connect()
        #expect(!harness.sending && harness.peer.pushes.isEmpty)
        harness.engine.phoneDisconnected()
        harness.pasteboard.copy(text: "fresh")
        harness.connect()
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        #expect(await harness.ackHandled())
        harness.engine.phoneDisconnected()
        harness.connect()
        #expect(!harness.sending && harness.peer.pushes.count == 1) // applied: nothing to replay
    }

    @Test("QC3: a card number is held with 'Send Anyway', which sends it with sensitive = true within 120 s")
    func sensitive() async {
        let harness = ClipboardHarness()
        harness.pasteboard.copy(text: "4111 1111 1111 1111")
        harness.engine.poll()
        #expect(harness.alerts == [.sensitiveBlocked] && harness.peer.pushes.isEmpty)
        harness.engine.sendAnyway()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        #expect(await harness.until { harness.engine.latestLocal?.appliedAt != nil }) // before the clock moves
        #expect(harness.peer.pushes[0].sensitive)
        harness.pasteboard.copy(text: "pw", extraTypes: ["org.nspasteboard.ConcealedType"])
        harness.engine.poll()
        #expect(harness.alerts.count == 2)
        harness.advance(121)
        harness.engine.sendAnyway()
        #expect(!harness.sending && harness.peer.pushes.count == 1) // expired
        harness.settings.blockSensitive = false
        harness.pasteboard.copy(text: "4111 1111 1111 1111")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 2 })
    }

    @Test("QC5: over 1 MiB → too large in place; over 180 KiB → chunks of 64 KiB with the SHA-256")
    func sizes() async throws {
        let harness = ClipboardHarness()
        harness.pasteboard.copy(text: String(repeating: "a", count: 1_048_577))
        harness.engine.poll()
        #expect(harness.notices == [.textTooLarge] && harness.peer.pushes.isEmpty)
        let text = String(repeating: "ă", count: 100_000) // 200,000 bytes of UTF-8
        harness.pasteboard.copy(text: text)
        harness.engine.poll()
        #expect(await harness.until { harness.peer.chunks.count == 4 })
        let push = try #require(harness.peer.pushes.first)
        let transfer = try #require(push.transfer)
        #expect(push.text == nil && push.kind == .text && transfer.size == 200_000 && transfer.chunkCount == 4)
        #expect(transfer.chunkSize == 65_536)
        #expect(transfer.sha256 == Base64Coding.encodeB64u(HMACSHA256.sha256(Data(text.utf8))))
        let joined = harness.peer.chunks.reduce(Data()) { $0 + $1.chunk }
        #expect(joined == Data(text.utf8) && harness.peer.chunks.map(\.index) == [0, 1, 2, 3])
    }

    @Test("CLIP-02 E1 and QC4: HandLive's own write and what just came from the phone are not sent back")
    func loopPrevention() async {
        let harness = ClipboardHarness()
        let id = harness.receive(ClipboardHarness.textPush("from the phone"))
        _ = await harness.reply(to: id)
        harness.engine.poll()
        harness.engine.sendClipboardNow()
        #expect(harness.notices == [.skippedJustReceived(deviceName: "Pixel của Lan")])
        // The same text copied again in another app within 5 s is still the phone's clip.
        harness.pasteboard.copy(text: "from the phone")
        harness.engine.poll()
        #expect(!harness.sending && harness.peer.pushes.isEmpty)
    }

    @Test("QC4: the clip just sent, written back by another clipboard tool, is not sent again for 5 s after the ack")
    func echoOfSentClip() async {
        let harness = ClipboardHarness()
        harness.pasteboard.copy(text: "https://example.com/echo")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        #expect(await harness.until { harness.engine.latestLocal?.appliedAt != nil })
        // An emulator's clipboard sharing writes the same text back: a new change without HandLive's mark.
        harness.advance(4)
        harness.pasteboard.copy(text: "https://example.com/echo")
        harness.engine.poll()
        #expect(!harness.sending && harness.peer.pushes.count == 1)
        // "Send Clipboard to Phone" still sends it; 5 s after the phone applied it, a copy of the same text is new.
        harness.engine.sendClipboardNow()
        #expect(await harness.until { harness.peer.pushes.count == 2 })
        #expect(await harness.until { harness.engine.latestLocal?.appliedAt != nil })
        harness.advance(6)
        harness.pasteboard.copy(text: "https://example.com/echo")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 3 })
    }

    @Test("QC4: an echo that overtakes a slow phone's ack is not sent again while the clip is unacknowledged")
    func echoBeforeAck() async {
        let harness = ClipboardHarness()
        harness.peer.answer(.timeout)
        harness.pasteboard.copy(text: "slow phone")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        #expect(await harness.ackHandled()) // no ack came: the clip stays unacknowledged
        harness.advance(20)
        harness.pasteboard.copy(text: "slow phone")
        harness.engine.poll()
        #expect(!harness.sending && harness.peer.pushes.count == 1)
    }

    @Test("An empty text is nothing copied: not sent; the menu item says the clipboard is empty")
    func emptyText() async {
        let harness = ClipboardHarness()
        // An emulator's clipboard sharing writes an empty text once the phone holds an image.
        harness.pasteboard.copy(text: "")
        harness.engine.poll()
        #expect(!harness.sending && harness.peer.pushes.isEmpty && harness.notices.isEmpty)
        harness.engine.sendClipboardNow()
        #expect(harness.notices == [.emptyOrNotText] && harness.peer.pushes.isEmpty)
    }

    @Test("Acks: INTERNAL → 'Couldn't update the clipboard on the phone'; FEATURE_DISABLED suspends until an update")
    func ackErrors() async {
        let harness = ClipboardHarness()
        harness.peer.answer(.error(.internal), .error(.featureDisabled))
        harness.pasteboard.copy(text: "one")
        harness.engine.poll()
        #expect(await harness.until { harness.notices == [.writeFailedOnPhone] })
        #expect(await harness.ackHandled())
        harness.pasteboard.copy(text: "two")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 2 })
        #expect(await harness.ackHandled()) // FEATURE_DISABLED handled: sending is suspended
        harness.pasteboard.copy(text: "three")
        harness.engine.poll()
        #expect(!harness.sending && harness.peer.pushes.count == 2) // suspended (E10)
        harness.engine.phoneCapabilityUpdated(ClipboardFeature(enabled: true, mimes: [ClipMime.text]))
        harness.pasteboard.copy(text: "four")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 3 })
    }

    @Test("macOS asks or refuses paste access: no automatic reading, the guide once per launch (C10, E2)")
    func pasteAccess() {
        let harness = ClipboardHarness()
        harness.readingAllowed = false
        harness.pasteboard.copy(text: "a")
        harness.engine.poll()
        harness.pasteboard.copy(text: "b")
        harness.engine.poll()
        #expect(harness.notices == [.pasteAccessNeeded] && harness.peer.pushes.isEmpty)
    }

    @Test("HTML beside the text: sent inline only to a phone listing text/html; the text stays the identity")
    func htmlOnlyToPhoneThatListsIt() async {
        let withHtml = ClipboardHarness(feature: ClipboardHarness.htmlFeature)
        withHtml.pasteboard.copy(text: "Hi Lan", html: "<p onclick=\"x\">Hi <b>Lan</b></p>")
        withHtml.engine.poll()
        #expect(await withHtml.until { withHtml.peer.pushes.count == 1 })
        #expect(withHtml.peer.pushes[0].text == "Hi Lan" && withHtml.peer.pushes[0].html == "<p>Hi <b>Lan</b></p>")
        #expect(withHtml.engine.latestLocal?.content.sha256 == ClipContent.text("Hi Lan").sha256)

        let plain = ClipboardHarness() // the default phone lists no text/html
        plain.pasteboard.copy(text: "Hi Lan", html: "<b>Lan</b>")
        plain.engine.poll()
        #expect(await plain.until { plain.peer.pushes.count == 1 })
        #expect(plain.peer.pushes[0].text == "Hi Lan" && plain.peer.pushes[0].html == nil)
    }

    @Test("HTML is dropped when the push would pass CLIP_INLINE_MAX or the HTML passes CLIP_MAX_HTML; a chunked text has none")
    func htmlDroppedWhenTooLarge() async {
        let harness = ClipboardHarness(feature: ClipboardHarness.htmlFeature)
        let text = String(repeating: "a", count: 100 * 1024)
        harness.pasteboard.copy(text: text, html: "<p>" + String(repeating: "b", count: 100 * 1024) + "</p>")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        #expect(harness.peer.pushes[0].text == text && harness.peer.pushes[0].html == nil) // 200 KiB together

        let huge = "<p>" + String(repeating: "c", count: ClipboardConstants.maxHtmlBytes) + "</p>"
        harness.pasteboard.copy(text: "short", html: huge)
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 2 })
        #expect(harness.peer.pushes[1].text == "short" && harness.peer.pushes[1].html == nil)

        harness.pasteboard.copy(text: String(repeating: "d", count: 200 * 1024), html: "<p>d</p>")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 3 })
        #expect(harness.peer.pushes[2].transfer != nil && harness.peer.pushes[2].html == nil)
    }

    @Test("Send Anyway keeps the HTML of the held clip")
    func sendAnywayKeepsHtml() async {
        let harness = ClipboardHarness(feature: ClipboardHarness.htmlFeature)
        harness.pasteboard.copy(text: "4111 1111 1111 1111", html: "<b>4111 1111 1111 1111</b>")
        harness.engine.poll()
        #expect(harness.alerts == [.sensitiveBlocked])
        harness.engine.sendAnyway()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        #expect(harness.peer.pushes[0].sensitive && harness.peer.pushes[0].html == "<b>4111 1111 1111 1111</b>")
    }
}
