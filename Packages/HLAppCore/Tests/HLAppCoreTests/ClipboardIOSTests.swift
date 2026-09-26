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

    @Test("E9: no ack in time says Couldn't send and never replays")
    func noAck() async throws {
        let harness = ClipboardHarness(platform: .ios)
        harness.peer.answer(.timeout)
        harness.engine.sendPasted(.text("Hẹn 3h"))
        #expect(await harness.until { harness.notices.contains(.sendFailed) })
        harness.engine.phoneDisconnected()
        harness.connect()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.peer.pushes.count == 1)
    }
}
