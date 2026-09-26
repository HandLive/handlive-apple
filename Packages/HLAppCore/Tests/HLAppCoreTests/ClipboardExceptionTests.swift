import Foundation
import HLCrypto
import HLProtocol
import HLTransport
import Testing
@testable import HLAppCore

/// The remaining exceptions of CLIP-02, CLIP-03 and CLIP-05 on the Mac.
@Suite("Clipboard: exceptions (CLIP-02 E9, CLIP-03 E2/E3/E6/E8/E9, CLIP-05 E2/E6)")
@MainActor
struct ClipboardExceptionTests {
    @Test("CLIP-02 E9: no ack within 10 s → not received; replayed when the next session starts")
    func noAckIsReplayed() async {
        let harness = ClipboardHarness()
        harness.peer.answer(.timeout)
        harness.pasteboard.copy(text: "lost ack")
        harness.engine.poll()
        #expect(await harness.until { harness.peer.pushes.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        harness.engine.phoneDisconnected()
        harness.connect()
        #expect(await harness.until { harness.peer.pushes.count == 2 })
        #expect(harness.peer.pushes[1].clipId == harness.peer.pushes[0].clipId)
    }

    @Test("CLIP-03 E2 and E3: an image over the phone's limit and an unreadable image are reported in place")
    func imageLimits() async throws {
        let harness = ClipboardHarness(feature: ClipboardFeature(enabled: true, maxImageBytes: 100,
                                                                 mimes: [ClipMime.text, ClipMime.png]))
        harness.pasteboard.copy([(PasteboardTypeID.png, try ClipboardTransferTests.png(side: 16))])
        harness.engine.poll()
        #expect(await harness.until { harness.notices == [.imageTooLarge] })
        harness.pasteboard.copy([(PasteboardTypeID.png, Data("not an image".utf8))])
        harness.engine.sendClipboardNow()
        #expect(await harness.until { harness.notices.last == .imageUnreadable })
        #expect(harness.peer.pushes.isEmpty)
    }

    @Test("CLIP-03 E6 on the sending side: Cancel → clipboard/cancel user, no more chunks, not replayed")
    func userCancelsSending() async throws {
        let harness = ClipboardHarness()
        harness.peer.chunkDelay = .milliseconds(30)
        harness.pasteboard.copy([(PasteboardTypeID.png, try ClipboardTransferTests.png(side: 700))])
        harness.engine.poll()
        #expect(await harness.until { harness.progress[.sending] != nil })
        let transferId = try #require(harness.progress[.sending]?.transferId)
        harness.engine.cancelTransfer(transferId)
        #expect(await harness.until { harness.peer.cancels == [ClipboardCancelData(transferId: transferId, reason: .user)] })
        #expect(harness.progress[.sending] == nil)
        let sent = harness.peer.chunks.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.peer.chunks.count <= sent + 1)
        harness.engine.phoneDisconnected()
        harness.connect()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.peer.pushes.count == 1)
    }

    @Test("CLIP-03 E8: a lost session drops the incoming transfer and its file; E9: no room → INTERNAL")
    func lostSessionAndNoSpace() async throws {
        let harness = ClipboardHarness()
        let data = Data(repeating: 3, count: 150_000)
        let transfer = ClipboardTransferTests.transfer(for: data)
        _ = harness.receive(ClipboardTransferTests.imagePush(transfer))
        harness.receiveChunk(ClipboardTransferTests.chunks(of: data, transfer: transfer)[0])
        let file = try #require(harness.engine.incoming?.fileURL)
        #expect(FileManager.default.fileExists(atPath: file.path))
        harness.engine.phoneDisconnected()
        #expect(harness.engine.incoming == nil && !FileManager.default.fileExists(atPath: file.path))
        harness.connect()
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("hl-not-a-dir-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        let full = ClipboardEngine(access: harness.pasteboard, settings: harness.settings, deviceId: ClipboardHarness.macId,
                                   deviceName: "Mac", readingAllowed: { true }, temporaryDirectory: blocker)
        var notices: [ClipboardNotice] = []
        full.onNotice = { notices.append($0) }
        full.phoneConnected(peer: harness.peer, deviceId: ClipboardHarness.phoneId, name: "Pixel", feature: nil)
        let push = ClipboardTransferTests.imagePush(ClipboardTransferTests.transfer(for: data))
        let id = HLUUID.v7()
        let payload = Payload(op: "push", data: try HLJSON.convert(from: push))
        full.receive(IncomingEnvelope(id: id, type: .clipboard, ts: 0, body: .json(payload)))
        #expect(await harness.reply(to: id)?.error?.code == .internal)
        #expect(notices == [.imageNoSpace])
    }

    @Test("CLIP-05 E2: a new clip restarts the deadline; E6: a deadline passed during sleep is checked on wake")
    func newClipAndWake() async {
        let harness = ClipboardHarness()
        _ = await harness.reply(to: harness.receive(ClipboardHarness.textPush("first")))
        harness.advance(50)
        _ = await harness.reply(to: harness.receive(ClipboardHarness.textPush("second")))
        harness.advance(20)
        harness.engine.checkAutoClear()
        #expect(harness.pasteboard.types.contains(PasteboardTypeID.text)) // 20 s into the new clip's minute
        harness.engine.systemWillSleep()
        harness.advance(45)
        harness.engine.systemDidWake(pollingWanted: false)
        #expect(harness.pasteboard.types.isEmpty)
    }
}
