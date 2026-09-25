import CoreGraphics
import Foundation
import HLCrypto
import HLProtocol
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HLAppCore

/// CLIP-03: chunked images (and long text) in both directions.
@Suite("Clipboard: chunked transfers (CLIP-03)")
@MainActor
struct ClipboardTransferTests {
    /// A PNG of random pixels (incompressible), `side` × `side`.
    static func png(side: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8]((0..<(side * side * 4)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let context = try #require(CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func transfer(for data: Data, sha: Data? = nil) -> ClipboardTransfer {
        ClipboardTransfer(transferId: HLUUID.v7(), size: Int64(data.count),
                          sha256: Base64Coding.encodeB64u(sha ?? HMACSHA256.sha256(data)), chunkSize: 65_536,
                          chunkCount: Int32((data.count + 65_535) / 65_536))
    }

    static func imagePush(_ transfer: ClipboardTransfer) -> ClipboardPushData {
        ClipboardPushData(clipId: HLUUID.v7(), kind: .image, mime: ClipMime.png, transfer: transfer, width: 700, height: 700,
                          sensitive: false, originTs: 1_727_150_000_000, source: .auto, originDeviceId: ClipboardHarness.phoneId)
    }

    static func chunks(of data: Data, transfer: ClipboardTransfer) -> [ClipboardChunkPlaintext] {
        stride(from: 0, to: data.count, by: 65_536).enumerated().map { index, start in
            ClipboardChunkPlaintext(transferId: transfer.transferId, index: Int32(index),
                                    chunk: data.subdata(in: start..<min(start + 65_536, data.count)))
        }
    }

    @Test("An image in chunks: progress over 1 MiB, SHA-256 checked, written as PNG, acknowledged applied")
    func receiveImage() async throws {
        let harness = ClipboardHarness()
        let image = try Self.png(side: 700)
        #expect(image.count > 1_048_576)
        let transfer = Self.transfer(for: image)
        let push = Self.imagePush(transfer)
        let id = harness.receive(push)
        for chunk in Self.chunks(of: image, transfer: transfer) { harness.receiveChunk(chunk) }
        let ack = try #require(await harness.reply(to: id))
        #expect(ack.clipboardData == ClipboardAckData(clipId: push.clipId, status: .applied))
        #expect(harness.pasteboard.writes.first?.content == .image(ClipImage(data: image, mime: ClipMime.png, width: 700,
                                                                             height: 700)))
        #expect(harness.progressSeen && harness.progress[.receiving] == nil)
    }

    @Test("Wrong SHA-256 → CLIP_CHECKSUM_MISMATCH with transfer_id; a chunk out of order → BAD_REQUEST")
    func receiveFailures() async throws {
        let harness = ClipboardHarness()
        let data = Data(repeating: 7, count: 200_000)
        let bad = Self.transfer(for: data, sha: Data(count: 32))
        let badPush = Self.imagePush(bad)
        let first = harness.receive(badPush)
        for chunk in Self.chunks(of: data, transfer: bad) { harness.receiveChunk(chunk) }
        let mismatch = try #require(await harness.reply(to: first))
        #expect(mismatch.error?.code == .clipChecksumMismatch)
        #expect(mismatch.clipboardData == ClipboardAckData(clipId: badPush.clipId, status: .rejected, transferId: bad.transferId))
        let transfer = Self.transfer(for: data)
        let second = harness.receive(Self.imagePush(transfer))
        harness.receiveChunk(Self.chunks(of: data, transfer: transfer)[1])
        #expect(await harness.reply(to: second)?.error?.code == .badRequest)
        #expect(harness.pasteboard.writes.isEmpty)
    }

    @Test("Cancels: from the phone, by the user here, after 30 s without a chunk, and a newer push replacing the transfer")
    func cancels() async throws {
        let harness = ClipboardHarness()
        let data = Data(repeating: 1, count: 150_000)
        var transfer = Self.transfer(for: data)
        var id = harness.receive(Self.imagePush(transfer))
        harness.receive(.cancel, ClipboardCancelData(transferId: transfer.transferId, reason: .superseded))
        #expect(await harness.reply(to: id)?.clipboardData?.reason == .cancelled)
        transfer = Self.transfer(for: data)
        id = harness.receive(Self.imagePush(transfer))
        harness.engine.cancelTransfer(transfer.transferId)
        #expect(await harness.reply(to: id)?.clipboardData?.reason == .cancelled)
        let userCancel = ClipboardCancelData(transferId: transfer.transferId, reason: .user)
        #expect(await harness.until { harness.peer.cancels.last == userCancel })
        harness.engine.transferIdleTimeout = .milliseconds(100)
        transfer = Self.transfer(for: data)
        id = harness.receive(Self.imagePush(transfer))
        harness.receiveChunk(Self.chunks(of: data, transfer: transfer)[0])
        #expect(await harness.reply(to: id)?.clipboardData?.reason == .cancelled)
        #expect(harness.peer.cancels.last == ClipboardCancelData(transferId: transfer.transferId, reason: .timeout))
        harness.engine.transferIdleTimeout = .seconds(30)
        let replaced = harness.receive(Self.imagePush(Self.transfer(for: data)))
        _ = harness.receive(ClipboardHarness.textPush("newer"))
        #expect(await harness.reply(to: replaced)?.clipboardData?.reason == .cancelled)
    }

    @Test("Sending an image: PNG kept as is, width and height, chunks and progress; images off or not taken → not sent")
    func sendImage() async throws {
        let harness = ClipboardHarness()
        let image = try Self.png(side: 700)
        harness.pasteboard.copy([(PasteboardTypeID.png, image)])
        harness.engine.poll()
        #expect(await harness.until { harness.peer.chunks.count == (image.count + 65_535) / 65_536 })
        let push = try #require(harness.peer.pushes.first)
        #expect(push.kind == .image && push.mime == ClipMime.png && push.width == 700 && push.height == 700)
        #expect(push.transfer?.sha256 == Base64Coding.encodeB64u(HMACSHA256.sha256(image)))
        #expect(await harness.until { harness.progressSeen && harness.progress[.sending] == nil })
        harness.settings.sendImages = false
        harness.pasteboard.copy([(PasteboardTypeID.png, image)])
        harness.engine.poll()
        harness.settings.sendImages = true
        harness.engine.phoneCapabilityUpdated(ClipboardFeature(enabled: true, mimes: [ClipMime.text, ClipMime.jpeg]))
        harness.pasteboard.copy([(PasteboardTypeID.png, try Self.png(side: 8))])
        harness.engine.poll()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.peer.pushes.count == 1)
    }

    @Test("CLIP_CHECKSUM_MISMATCH: resent once with a new transfer_id and the same clip_id; twice → 'Couldn't send the image'")
    func resendOnce() async throws {
        let harness = ClipboardHarness()
        harness.peer.answer(.error(.clipChecksumMismatch), .error(.clipChecksumMismatch))
        harness.pasteboard.copy([(PasteboardTypeID.png, try Self.png(side: 64))])
        harness.engine.poll()
        #expect(await harness.until { harness.notices == [.imageSendFailed] })
        let pushes = harness.peer.pushes
        #expect(pushes.count == 2 && pushes[0].clipId == pushes[1].clipId)
        #expect(pushes[0].transfer?.transferId != pushes[1].transfer?.transferId)
    }

    @Test("A newer copy cancels the transfer in progress with superseded")
    func superseded() async throws {
        let harness = ClipboardHarness()
        harness.peer.chunkDelay = .milliseconds(30)
        harness.pasteboard.copy(text: String(repeating: "x", count: 400_000))
        harness.engine.poll()
        #expect(await harness.until { !harness.peer.chunks.isEmpty })
        let transferId = try #require(harness.peer.pushes.first?.transfer?.transferId)
        harness.pasteboard.copy(text: "newer")
        harness.engine.poll()
        let supersede = ClipboardCancelData(transferId: transferId, reason: .superseded)
        #expect(await harness.until { harness.peer.cancels == [supersede] })
        #expect(await harness.until { harness.peer.pushes.last?.text == "newer" })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.peer.chunks.count < 7)
    }
}
