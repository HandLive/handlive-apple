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
        #expect(!model.canSendClipboard)
        try model.completePairing(PairingControllerTests.result())
        #expect(model.clipboardPollingWanted && engine.isPolling)
        #expect(model.canSendClipboard) // offline too: the clip waits for the phone (CLIP-02 E6)
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

    @Test("Ghi chú Bluetooth dưới tiến độ (CLIP-03 trường 10): chỉ khi đi qua Bluetooth, đúng chiều gửi/nhận")
    func bluetoothNote() {
        func progress(_ direction: ClipboardProgress.Direction, overBluetooth: Bool) -> ClipboardProgress {
            ClipboardProgress(direction: direction, transferId: HLUUID.v7(), deviceName: "Pixel 8", fraction: 0.2,
                              overBluetooth: overBluetooth)
        }
        #expect(progress(.sending, overBluetooth: true).bluetoothNote == L10n.Clipboard.bulkBluetoothSending)
        #expect(progress(.receiving, overBluetooth: true).bluetoothNote == L10n.Clipboard.bulkBluetoothReceiving)
        #expect(progress(.sending, overBluetooth: false).bluetoothNote == nil)
        #expect(progress(.receiving, overBluetooth: false).bluetoothNote == nil)
    }
}
