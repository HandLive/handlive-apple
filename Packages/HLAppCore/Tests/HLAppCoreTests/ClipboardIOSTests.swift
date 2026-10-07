import Foundation
import HLProtocol
import Testing
@testable import HLAppCore

/// CLIP-04 on the iPhone and iPad: the clipboard is never read, only `changeCount`; the user sends with the system
/// Paste button; a push right after connecting does not overwrite what was copied here and not sent yet.
@Suite("Clipboard on iPhone and iPad (CLIP-04)")
@MainActor
struct ClipboardIOSTests {
    @Test("A copy here marks unsent content and saves the seen changeCount; nothing is read, HandLive's writes don't count")
    func unsentContent() async throws {
        let harness = ClipboardHarness(platform: .ios)
        harness.pasteboard.copy(text: "số tài khoản 0123")
        harness.engine.localChangeSeen()
        #expect(harness.engine.unsentLocalContent && harness.unsentBanner == [true])
        #expect(harness.settings.seenChangeCount == harness.pasteboard.changeCount)
        harness.engine.poll() // the Mac's poll does not read here either
        #expect(harness.pasteboard.contentReads == 0 && harness.peer.pushes.isEmpty)
        harness.engine.dismissUnsentLocalContent()
        harness.advance(10)
        let request = harness.receive(ClipboardHarness.textPush("từ điện thoại"))
        #expect(await harness.reply(to: request)?.clipboardData?.status == .applied)
        harness.engine.localChangeSeen() // the write was HandLive's own
        #expect(!harness.engine.unsentLocalContent && harness.unsentBanner == [true, false])
    }

    @Test("A pasted text goes at once with source ios and hides the banner; too large or images off are refused")
    func sendPasted() async throws {
        let harness = ClipboardHarness(platform: .ios)
        harness.pasteboard.copy(text: "Hẹn 3h")
        harness.engine.localChangeSeen()
        harness.engine.sendPasted(.text("Hẹn 3h"))
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        let push = try #require(harness.peer.pushes.first)
        #expect(push.source == .ios && push.text == "Hẹn 3h" && !push.sensitive)
        #expect(!harness.engine.unsentLocalContent)
        #expect(await harness.until { harness.notices.contains(.sent(deviceName: "Pixel của Lan")) })
        harness.engine.sendPasted(.text(String(repeating: "a", count: ClipboardConstants.maxTextBytes + 1)))
        #expect(harness.notices.last == .textTooLarge)
        harness.settings.sendImages = false
        harness.engine.sendPasted(.image(ClipImage(data: Data([1, 2, 3]), mime: ClipMime.png, width: 1, height: 1)))
        #expect(harness.notices.last == .unsupportedContent && harness.peer.pushes.count == 1)
    }

    @Test("A pasted text with HTML goes with its html to a phone that lists text/html; copying again keeps it")
    func sendPastedWithHtml() async throws {
        let harness = ClipboardHarness(platform: .ios, feature: ClipboardHarness.htmlFeature)
        harness.engine.sendPasted(.text("Hẹn 3h"), html: "<p>Hẹn <b>3h</b></p>")
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        #expect(await harness.pushSettled()) // else the clip is still unacknowledged and the next push is a conflict
        #expect(harness.peer.pushes[0].text == "Hẹn 3h" && harness.peer.pushes[0].html == "<p>Hẹn <b>3h</b></p>")
        let received = ClipboardHarness.textPush("từ Mac", html: "<i>từ Mac</i>")
        #expect(await harness.reply(to: harness.receive(received))?.clipboardData?.status == .applied)
        #expect(harness.pasteboard.writes.last?.html == "<i>từ Mac</i>")
        #expect(harness.engine.copyLastReceivedAgain())
        #expect(harness.pasteboard.writes.count == 2 && harness.pasteboard.writes[1].html == "<i>từ Mac</i>")
    }

    @Test("E2: unsent content survives a push in the first 5 s of the session; a later push is written")
    func firstSecondsKeepLocalContent() async throws {
        let harness = ClipboardHarness(connected: false, platform: .ios)
        harness.pasteboard.copy(text: "chưa gửi")
        harness.engine.localChangeSeen()
        harness.connect()
        harness.advance(2)
        let early = harness.receive(ClipboardHarness.textPush("cũ", originTs: 1_727_149_999_000))
        let ack = await harness.reply(to: early)
        #expect(ack?.clipboardData?.status == .ignored && ack?.clipboardData?.reason == .conflict)
        #expect(harness.pasteboard.writes.isEmpty && harness.peer.conflicts.isEmpty)
        harness.advance(4)
        let later = harness.receive(ClipboardHarness.textPush("mới", originTs: 1_727_150_006_000))
        #expect(await harness.reply(to: later)?.clipboardData?.status == .applied)
        #expect(harness.pasteboard.writes.map(\.content) == [.text("mới")])
    }

    @Test("Background grace: pushes are written until the user copies elsewhere; then the copy stays, banner on return")
    func graceKeepsANewLocalCopy() async throws {
        let harness = ClipboardHarness(platform: .ios)
        harness.advance(10) // past the first 5 s of the session
        harness.engine.protectLocalContent(true)
        let first = harness.receive(ClipboardHarness.textPush("một"))
        #expect(await harness.reply(to: first)?.clipboardData?.status == .applied)
        let second = harness.receive(ClipboardHarness.textPush("hai")) // after HandLive's own write: still written
        #expect(await harness.reply(to: second)?.clipboardData?.status == .applied)
        harness.advance(61)
        harness.engine.checkAutoClear() // HandLive's own clear moves the reference too
        let cleared = harness.receive(ClipboardHarness.textPush("sau khi xóa"))
        #expect(await harness.reply(to: cleared)?.clipboardData?.status == .applied)
        harness.pasteboard.copy(text: "chép trong Safari")
        let third = harness.receive(ClipboardHarness.textPush("ba"))
        let ack = await harness.reply(to: third)
        #expect(ack?.clipboardData?.status == .ignored && ack?.clipboardData?.reason == .conflict)
        #expect(harness.pasteboard.writes.map(\.content) == [.text("một"), .text("hai"), .text("sau khi xóa")])
        #expect(harness.engine.unsentLocalContent && harness.pasteboard.contentReads == 0)
        harness.engine.protectLocalContent(false)
        let fourth = harness.receive(ClipboardHarness.textPush("bốn")) // back in the foreground: the 5 s rule again
        #expect(await harness.reply(to: fourth)?.clipboardData?.status == .applied)
    }

    @Test("The last received clip is kept for the card and can be copied again as HandLive's own write")
    func lastReceived() async throws {
        let harness = ClipboardHarness(platform: .ios)
        var shown: [ReceivedClip] = []
        harness.engine.onReceived = { shown.append($0) }
        harness.advance(6) // past the first 5 s: the clipboard's first changeCount counts as unsent content (E2)
        let request = harness.receive(ClipboardHarness.textPush("mã 123456", sensitive: true))
        #expect(await harness.reply(to: request)?.clipboardData?.status == .applied)
        let clip = try #require(harness.engine.lastReceived)
        #expect(clip.content == .text("mã 123456") && clip.sensitive && clip.deviceName == "Pixel của Lan")
        #expect(shown == [clip])
        harness.pasteboard.copy(text: "khác")
        #expect(harness.engine.copyLastReceivedAgain())
        #expect(harness.pasteboard.writes.count == 2 && harness.pasteboard.writes.last?.sensitive == true)
        harness.engine.localChangeSeen()
        #expect(!harness.engine.unsentLocalContent) // the copy again is HandLive's own write
        #expect(!LocalDevice.current(name: "iPhone", platform: .ios).model.isEmpty)
    }

    @Test("E9: no ack in time says Couldn't send and never replays")
    func noAck() async throws {
        let harness = ClipboardHarness(platform: .ios)
        harness.peer.answer(.timeout)
        harness.engine.sendPasted(.text("Hẹn 3h"))
        #expect(await harness.until { harness.notices.contains(.sendFailed) })
        #expect(await harness.pushSettled())
        harness.engine.phoneDisconnected()
        harness.connect()
        #expect(!harness.sending && harness.peer.pushes.count == 1)
    }
}
