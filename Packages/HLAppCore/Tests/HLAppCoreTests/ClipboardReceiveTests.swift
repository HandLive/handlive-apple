import Foundation
import HLCrypto
import HLProtocol
import HLTransport
import Testing
@testable import HLAppCore

/// CLIP-01 (phone → Mac), the receiving half of CLIP-03 and QC6–QC8.
@Suite("Clipboard: receiving on the Mac")
@MainActor
struct ClipboardReceiveTests {
    @Test("An inline text is written with the clip-id mark, concealed when sensitive, and acknowledged applied")
    func writesText() async throws {
        let harness = ClipboardHarness()
        let push = ClipboardHarness.textPush("Order number: HL-240917-0042", sensitive: true)
        let ack = try #require(await harness.reply(to: harness.receive(push)))
        #expect(ack.ok && ack.clipboardData == ClipboardAckData(clipId: push.clipId, status: .applied))
        #expect(harness.pasteboard.writes == [FakePasteboard.Write(content: .text("Order number: HL-240917-0042"),
                                                                   clipId: push.clipId, sensitive: true)])
        #expect(harness.pasteboard.types.contains(PasteboardTypeID.concealed))
        #expect(harness.engine.ownWrite?.clipId == push.clipId)
    }

    @Test("QC6: the same clip_id again is ignored as a duplicate and not written twice")
    func duplicate() async throws {
        let harness = ClipboardHarness()
        let push = ClipboardHarness.textPush("once")
        _ = await harness.reply(to: harness.receive(push))
        let again = try #require(await harness.reply(to: harness.receive(push)))
        #expect(again.clipboardData == ClipboardAckData(clipId: push.clipId, status: .ignored, reason: .duplicate))
        #expect(harness.pasteboard.writes.count == 1)
    }

    @Test("Validation: kind/mime, text and transfer together, clipboard off, images off, too large, write failure")
    func rejections() async throws {
        let harness = ClipboardHarness()
        func code(_ push: ClipboardPushData) async -> ErrorCode? {
            await harness.reply(to: harness.receive(push))?.error?.code
        }
        let base = ClipboardHarness.textPush("x")
        #expect(await code(ClipboardPushData(clipId: HLUUID.v7(), kind: .image, mime: ClipMime.text, text: "x", sensitive: false,
                                             originTs: 1, source: .auto, originDeviceId: base.originDeviceId)) == .badRequest)
        let transfer = ClipboardTransfer(transferId: HLUUID.v7(), size: 1, sha256: Base64Coding.encodeB64u(Data(count: 32)),
                                         chunkSize: 65_536, chunkCount: 1)
        #expect(await code(ClipboardPushData(clipId: HLUUID.v7(), kind: .text, mime: ClipMime.text, text: "x", transfer: transfer,
                                             sensitive: false, originTs: 1, source: .auto,
                                             originDeviceId: base.originDeviceId)) == .badRequest)
        #expect(await code(ClipboardHarness.textPush(String(repeating: "a", count: 1_048_577))) == .clipTooLarge)
        harness.settings.sendImages = false
        #expect(await code(ClipboardPushData(clipId: HLUUID.v7(), kind: .image, mime: ClipMime.png, transfer: transfer,
                                             sensitive: false, originTs: 1, source: .auto,
                                             originDeviceId: base.originDeviceId)) == .clipUnsupportedMime)
        harness.pasteboard.failWrites = true
        let failed = ClipboardHarness.textPush("y")
        let ack = await harness.reply(to: harness.receive(failed))
        #expect(ack?.error?.code == .internal && ack?.clipboardData == ClipboardAckData(clipId: failed.clipId, status: .rejected))
        harness.settings.clipboardEnabled = false
        #expect(await code(ClipboardHarness.textPush("z")) == .featureDisabled)
    }

    @Test("QC8 (a): a copy on the Mac just before the push keeps the local content and reports the conflict")
    func freshLocalChangeWins() async throws {
        let harness = ClipboardHarness()
        harness.pasteboard.copy(text: "copied on the Mac") // not polled yet
        let push = ClipboardHarness.textPush("from the phone")
        let ack = try #require(await harness.reply(to: harness.receive(push)))
        #expect(ack.clipboardData == ClipboardAckData(clipId: push.clipId, status: .ignored, reason: .conflict))
        #expect(await harness.until { harness.peer.conflicts.count == 1 })
        #expect(harness.peer.conflicts[0] == ClipboardConflictData(clipId: push.clipId, originDeviceId: ClipboardHarness.phoneId,
                                                                   deviceId: ClipboardHarness.macId,
                                                                   deviceName: "MacBook của Lan"))
        #expect(harness.pasteboard.writes.isEmpty)
        #expect(await harness.until { harness.peer.pushes.first?.text == "copied on the Mac" })
    }

    @Test("QC8 (b): crossing clips — the larger origin_ts wins on both sides, no conflict message")
    func crossingClips() async throws {
        let harness = ClipboardHarness()
        harness.peer.answer(.timeout, .timeout)
        harness.pasteboard.copy(text: "mac clip")
        harness.engine.poll() // unacknowledged local clip, origin_ts = clock
        harness.advance(2)
        let older = ClipboardHarness.textPush("older phone clip", originTs: 1_727_149_999_000)
        let keep = try #require(await harness.reply(to: harness.receive(older)))
        #expect(keep.clipboardData?.reason == .conflict && harness.pasteboard.writes.isEmpty)
        let newer = ClipboardHarness.textPush("newer phone clip", originTs: 1_727_150_001_000)
        let applied = try #require(await harness.reply(to: harness.receive(newer)))
        #expect(applied.clipboardData?.status == .applied && harness.peer.conflicts.isEmpty)
        #expect(harness.engine.latestLocal == nil) // the Mac clip lost: not replayed
    }

    @Test("clipboard/conflict for the latest clip: 'Send Again' sends the same content as a new clip within 120 s")
    func sendAgain() async throws {
        let harness = ClipboardHarness()
        harness.peer.answer(.ignored(.conflict))
        harness.pasteboard.copy(text: "keep trying")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        let first = harness.peer.pushes[0]
        harness.receive(.conflict, ClipboardConflictData(clipId: first.clipId, originDeviceId: ClipboardHarness.macId,
                                                         deviceId: ClipboardHarness.phoneId, deviceName: "Pixel của Lan"))
        #expect(harness.alerts == [.conflict(deviceName: "Pixel của Lan")])
        harness.engine.sendAgain()
        #expect(await harness.until { harness.peer.pushes.count == 2 })
        #expect(harness.peer.pushes[1].text == "keep trying" && harness.peer.pushes[1].clipId != first.clipId)
    }
}
