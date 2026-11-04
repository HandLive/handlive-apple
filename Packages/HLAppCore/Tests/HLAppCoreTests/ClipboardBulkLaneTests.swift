import Foundation
import HLCrypto
import HLProtocol
import HLTransport
import Testing
@testable import HLAppCore

/// 0.4.7 "Bulk lane on the Bluetooth link" luật 1: bên gửi chọn lane. Đúng các phong bì của một transfer CLIP-03
/// đi lane bulk; mọi phong bì khác (push nội tuyến, ack và conflict của nó) ở lại lane control.
@Suite("Clipboard: lane of each envelope (0.4.7 bulk rule 1)")
@MainActor
struct ClipboardBulkLaneTests {
    @Test("0.4.7 bulk rule 1: an inline push goes on the control lane")
    func inlinePushIsControl() async throws {
        let harness = ClipboardHarness()
        harness.pasteboard.copy(text: "xin chào")
        harness.engine.poll()
        #expect(await harness.until { !harness.peer.pushes.isEmpty })
        #expect(harness.peer.lanes("push") == [.control])
        #expect(harness.peer.lanes("chunk").isEmpty)
    }

    @Test("0.4.7 bulk rule 1: the push of a transfer and every chunk go on the bulk lane")
    func sendTransferIsBulk() async throws {
        let harness = ClipboardHarness()
        let image = try ClipboardTransferTests.png(side: 700)
        harness.pasteboard.copy([(PasteboardTypeID.png, image)])
        harness.engine.poll()
        let chunkCount = (image.count + 65_535) / 65_536
        #expect(await harness.until { harness.peer.chunks.count == chunkCount })
        #expect(harness.peer.lanes("push") == [.bulk])
        #expect(harness.peer.lanes("chunk") == Array(repeating: .bulk, count: chunkCount))
    }

    @Test("0.4.7 bulk rule 1: cancelling a transfer sends the cancel on the bulk lane")
    func cancelIsBulk() async throws {
        let harness = ClipboardHarness()
        harness.peer.chunkDelay = .milliseconds(30)
        harness.pasteboard.copy(text: String(repeating: "x", count: 400_000))
        harness.engine.poll()
        #expect(await harness.until { !harness.peer.chunks.isEmpty })
        harness.pasteboard.copy(text: "newer")
        harness.engine.poll()
        #expect(await harness.until { !harness.peer.cancels.isEmpty })
        #expect(harness.peer.lanes("cancel") == [.bulk])
    }

    @Test("0.4.7 bulk rule 1: the ack of an inline push goes on the control lane")
    func inlineAckIsControl() async throws {
        let harness = ClipboardHarness()
        let id = harness.receive(ClipboardHarness.textPush("từ điện thoại"))
        _ = try #require(await harness.reply(to: id))
        #expect(harness.peer.lanes("reply") == [.control])
    }

    @Test("0.4.7 bulk rule 1: the ack of a push with transfer goes on the bulk lane")
    func transferAckIsBulk() async throws {
        let harness = ClipboardHarness()
        let image = try ClipboardTransferTests.png(side: 700)
        let transfer = ClipboardTransferTests.transfer(for: image)
        let id = harness.receive(ClipboardTransferTests.imagePush(transfer))
        for chunk in ClipboardTransferTests.chunks(of: image, transfer: transfer) { harness.receiveChunk(chunk) }
        _ = try #require(await harness.reply(to: id))
        #expect(harness.peer.lanes("reply") == [.bulk])
    }

    @Test("0.4.7 bulk rule 1: the ack of a transfer rejected by a wrong SHA-256 goes on the bulk lane")
    func transferErrorAckIsBulk() async throws {
        let harness = ClipboardHarness()
        let image = try ClipboardTransferTests.png(side: 700)
        let transfer = ClipboardTransferTests.transfer(for: image, sha: Data(repeating: 0, count: 32))
        let id = harness.receive(ClipboardTransferTests.imagePush(transfer))
        for chunk in ClipboardTransferTests.chunks(of: image, transfer: transfer) { harness.receiveChunk(chunk) }
        _ = try #require(await harness.reply(to: id))
        #expect(harness.peer.lanes("reply") == [.bulk])
    }

    @Test("0.4.7 bulk rule 1: the conflict after a transfer ack goes on the bulk lane, after an inline ack on control")
    func conflictFollowsItsAck() async throws {
        let inline = ClipboardHarness()
        inline.pasteboard.copy(text: "bản trên Mac")
        _ = inline.receive(ClipboardHarness.textPush("bản trên điện thoại", originTs: 1_727_150_000_000))
        #expect(await inline.until { !inline.peer.conflicts.isEmpty })
        #expect(inline.peer.lanes("conflict") == [.control])

        let transferHarness = ClipboardHarness()
        let image = try ClipboardTransferTests.png(side: 700)
        transferHarness.pasteboard.copy(text: "bản trên Mac")
        let transfer = ClipboardTransferTests.transfer(for: image)
        _ = transferHarness.receive(ClipboardTransferTests.imagePush(transfer))
        for chunk in ClipboardTransferTests.chunks(of: image, transfer: transfer) { transferHarness.receiveChunk(chunk) }
        #expect(await transferHarness.until { !transferHarness.peer.conflicts.isEmpty })
        #expect(transferHarness.peer.lanes("conflict") == [.bulk])
    }
}

/// CLIP-03 field 2 và field 10: trên Bluetooth hiện tiến độ từ `BULK_DIRECT_MIN` (128 KiB), trên LAN và relay vẫn
/// chỉ khi ảnh lớn hơn 1 MiB; ghi chú "gửi qua Bluetooth" chỉ đi kèm tiến độ của đường Bluetooth.
@Suite("Clipboard: progress threshold by route (CLIP-03 fields 2 and 10)")
@MainActor
struct ClipboardBulkProgressTests {
    /// PNG ngẫu nhiên khoảng 190 KB: trên `BULK_DIRECT_MIN`, dưới 1 MiB.
    private static func mediumImage() throws -> Data { try ClipboardTransferTests.png(side: 220) }

    @Test("Bluetooth sending: an image of at least BULK_DIRECT_MIN shows progress marked as over Bluetooth")
    func bluetoothSendShowsProgress() async throws {
        let image = try Self.mediumImage()
        #expect(image.count >= TransportConstants.bulkDirectMin && image.count < ClipboardConstants.progressThreshold)
        let harness = ClipboardHarness(route: .bluetooth)
        var seen: [ClipboardProgress] = []
        harness.engine.onProgress = { direction, value in
            if direction == .sending, let value { seen.append(value) }
        }
        harness.pasteboard.copy([(PasteboardTypeID.png, image)])
        harness.engine.poll()
        #expect(await harness.until { harness.peer.chunks.count == (image.count + 65_535) / 65_536 })
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy(\.overBluetooth))
    }

    @Test("LAN sending: the same image under 1 MiB shows no progress")
    func lanSendShowsNoProgress() async throws {
        let image = try Self.mediumImage()
        let harness = ClipboardHarness(route: .lan)
        harness.pasteboard.copy([(PasteboardTypeID.png, image)])
        harness.engine.poll()
        #expect(await harness.until { harness.peer.chunks.count == (image.count + 65_535) / 65_536 })
        #expect(!harness.progressSeen)
    }

    @Test("Bluetooth sending: an image under BULK_DIRECT_MIN shows no progress")
    func smallImageOverBluetoothShowsNoProgress() async throws {
        let image = try ClipboardTransferTests.png(side: 100)
        #expect(image.count < TransportConstants.bulkDirectMin)
        let harness = ClipboardHarness(route: .bluetooth)
        harness.pasteboard.copy([(PasteboardTypeID.png, image)])
        harness.engine.poll()
        #expect(await harness.until { !harness.peer.pushes.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!harness.progressSeen)
    }

    @Test("Bluetooth receiving: an image of at least BULK_DIRECT_MIN shows progress marked as over Bluetooth")
    func bluetoothReceiveShowsProgress() async throws {
        let image = try Self.mediumImage()
        let harness = ClipboardHarness(route: .bluetooth)
        var seen: [ClipboardProgress] = []
        harness.engine.onProgress = { direction, value in
            if direction == .receiving, let value { seen.append(value) }
        }
        let transfer = ClipboardTransferTests.transfer(for: image)
        let id = harness.receive(ClipboardTransferTests.imagePush(transfer))
        for chunk in ClipboardTransferTests.chunks(of: image, transfer: transfer) { harness.receiveChunk(chunk) }
        _ = try #require(await harness.reply(to: id))
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy(\.overBluetooth))
    }

    @Test("LAN receiving: the same image under 1 MiB shows no progress")
    func lanReceiveShowsNoProgress() async throws {
        let image = try Self.mediumImage()
        let harness = ClipboardHarness(route: .lan)
        let transfer = ClipboardTransferTests.transfer(for: image)
        let id = harness.receive(ClipboardTransferTests.imagePush(transfer))
        for chunk in ClipboardTransferTests.chunks(of: image, transfer: transfer) { harness.receiveChunk(chunk) }
        _ = try #require(await harness.reply(to: id))
        #expect(!harness.progressSeen)
    }

    @Test("LAN sending: a 1 MiB image still shows progress, without the Bluetooth mark")
    func lanLargeImageStillShowsProgress() async throws {
        let image = try ClipboardTransferTests.png(side: 700)
        let harness = ClipboardHarness(route: .relay)
        var seen: [ClipboardProgress] = []
        harness.engine.onProgress = { direction, value in
            if direction == .sending, let value { seen.append(value) }
        }
        harness.pasteboard.copy([(PasteboardTypeID.png, image)])
        harness.engine.poll()
        #expect(await harness.until { harness.peer.chunks.count == (image.count + 65_535) / 65_536 })
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { !$0.overBluetooth })
    }
}
