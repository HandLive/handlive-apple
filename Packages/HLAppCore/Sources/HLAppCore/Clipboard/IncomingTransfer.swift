import CryptoKit
import Foundation
import HLProtocol

/// One chunked clip being received (CLIP-03 step 8): chunks go straight into `<transfer_id>.part` and an incremental
/// SHA-256, so the content is held in memory only once every check has passed.
@MainActor
final class IncomingTransfer {
    enum Step: Equatable {
        /// Chunks received so far over `chunk_count`.
        case progress(Double)
        case complete(Data)
        /// An `index` out of order (→ `BAD_REQUEST`).
        case outOfOrder
        /// Wrong total size or SHA-256 (→ `CLIP_CHECKSUM_MISMATCH`, E4).
        case checksumMismatch
    }

    let push: ClipboardPushData
    let transfer: ClipboardTransfer
    let requestId: String
    let fileURL: URL
    private let expectedDigest: Data
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var nextIndex: Int32 = 0
    private var receivedBytes: Int64 = 0
    var idleTimer: Task<Void, Never>?

    /// Throws when the temporary file cannot be created (E9, no space).
    init(push: ClipboardPushData, transfer: ClipboardTransfer, expectedDigest: Data, requestId: String,
         directory: URL) throws {
        self.push = push
        self.transfer = transfer
        self.expectedDigest = expectedDigest
        self.requestId = requestId
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("\(transfer.transferId).part")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        handle = try FileHandle(forWritingTo: fileURL)
    }

    var transferId: String { transfer.transferId }

    /// Appends the next chunk; throws on a disk error (E9).
    func append(_ chunk: ClipboardChunkPlaintext) throws -> Step {
        guard chunk.index == nextIndex, chunk.index < transfer.chunkCount, let handle else { return .outOfOrder }
        try handle.write(contentsOf: chunk.chunk)
        hasher.update(data: chunk.chunk)
        receivedBytes += Int64(chunk.chunk.count)
        nextIndex += 1
        guard nextIndex == transfer.chunkCount else {
            return .progress(Double(nextIndex) / Double(transfer.chunkCount))
        }
        try handle.close()
        self.handle = nil
        guard receivedBytes == transfer.size, Data(hasher.finalize()) == expectedDigest else { return .checksumMismatch }
        let data = try Data(contentsOf: fileURL)
        try? FileManager.default.removeItem(at: fileURL)
        return .complete(data)
    }

    /// Cancelled, failed or superseded: stop the timer and delete the temporary file.
    func discard() {
        idleTimer?.cancel()
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
