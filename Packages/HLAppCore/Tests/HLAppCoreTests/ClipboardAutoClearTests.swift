import Foundation
import HLProtocol
import Testing
@testable import HLAppCore

/// CLIP-05 on the Mac: only HandLive's own write is cleared, on the wall clock.
@Suite("Clipboard: auto-clear (CLIP-05)")
@MainActor
struct ClipboardAutoClearTests {
    @Test("Cleared at the deadline when changeCount still equals the write; the clearing is not taken for a copy")
    func clears() async {
        let harness = ClipboardHarness()
        _ = await harness.reply(to: harness.receive(ClipboardHarness.textPush("secret-ish")))
        harness.advance(59)
        harness.engine.checkAutoClear()
        #expect(!harness.pasteboard.types.isEmpty)
        harness.advance(2)
        harness.engine.checkAutoClear()
        #expect(harness.pasteboard.types.isEmpty && harness.engine.ownWrite == nil)
        harness.engine.poll()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.peer.pushes.isEmpty)
    }

    @Test("E1: a later copy is never cleared; E5: 0 turns the timer off")
    func keepsUserContent() async {
        let harness = ClipboardHarness()
        _ = await harness.reply(to: harness.receive(ClipboardHarness.textPush("from phone")))
        harness.pasteboard.copy(text: "mine")
        harness.advance(61)
        harness.engine.checkAutoClear()
        #expect(harness.pasteboard.types == [PasteboardTypeID.text])
        let other = ClipboardHarness()
        other.settings.autoClearSeconds = 0
        _ = await other.reply(to: other.receive(ClipboardHarness.textPush("kept")))
        other.advance(3_600)
        other.engine.checkAutoClear()
        #expect(!other.pasteboard.types.isEmpty)
    }

    @Test("E4: after a restart, a HandLive clip still on the clipboard gets a full interval again")
    func rearmsAfterRestart() async {
        let harness = ClipboardHarness()
        _ = await harness.reply(to: harness.receive(ClipboardHarness.textPush("left over")))
        harness.advance(45)
        let restarted = harness.makeEngine()
        #expect(restarted.ownWrite?.writtenAt == harness.clock)
        harness.advance(59)
        restarted.checkAutoClear()
        #expect(!harness.pasteboard.types.isEmpty)
        harness.advance(2)
        restarted.checkAutoClear()
        #expect(harness.pasteboard.types.isEmpty)
    }
}
