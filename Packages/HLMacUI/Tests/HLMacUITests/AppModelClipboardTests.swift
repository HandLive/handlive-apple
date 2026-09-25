import Foundation
import HLAppCore
import HLLocalization
import HLProtocol
import HLTransport
import Testing
@testable import HLMacUI

@Suite("Mac app model: clipboard")
@MainActor
struct AppModelClipboardTests {
    @Test("Polling runs only with a paired phone and Sync Clipboard on; a manual send offline says it will send later")
    func pollingAndManualSend() throws {
        let pasteboard = StubPasteboard()
        let model = makeModel(pasteboard: pasteboard)
        model.launch()
        let engine = try #require(model.clipboard)
        #expect(!model.clipboardPollingWanted && !engine.isPolling)
        try model.completePairing(PairingControllerTests.result())
        #expect(model.clipboardPollingWanted && engine.isPolling)
        model.setClipboardEnabled(false)
        #expect(!engine.isPolling)
        model.setClipboardEnabled(true)
        pasteboard.copy("hello")
        model.sendClipboard()
        #expect(model.menuStatusLine == L10n.Clipboard.notConnectedWillSend)
        model.forgetPair()
        #expect(!engine.isPolling)
    }

    @Test("Status lines, the checkmark after a manual send, and the progress text")
    func texts() async {
        let model = makeModel()
        model.show(.sent(deviceName: "Pixel 8"))
        #expect(model.menuStatusLine == "Sent to Pixel 8" && model.menuBarFeedback == "checkmark")
        model.show(.imageTooLarge)
        #expect(model.menuStatusLine == L10n.Error.clipImageTooLarge)
        #expect(ClipboardNotice.pasteAccessNeeded.text == L10n.Settings.pastePermissionHint)
        let progress = ClipboardProgress(direction: .receiving, transferId: HLUUID.v7(), deviceName: "Pixel 8", fraction: 0.45)
        #expect(progress.text == L10n.Clipboard.imageReceiving(deviceName: "Pixel 8", percent: "45%"))
    }
}
