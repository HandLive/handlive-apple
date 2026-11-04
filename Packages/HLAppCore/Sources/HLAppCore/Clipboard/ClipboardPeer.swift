import Foundation
import HLProtocol
import HLTransport

/// Waits for the `ack` of a request; `PendingAck` of a control session, or a fake in tests.
public protocol AckWaiting: Sendable {
    func response(timeout: Duration) async throws -> Ack
}

extension PendingAck: AckWaiting {}

/// The phone as the clipboard reaches it (Mac and iPhone have one peer, the phone — CLIP-02 API 2 logic 1).
public protocol ClipboardPeer: Sendable {
    /// `clipboard/push` as a request; the caller decides when to start waiting (after the last chunk).
    func sendPush(_ push: ClipboardPushData, lane: EnvelopeLane) async throws -> any AckWaiting
    func sendChunk(_ chunk: ClipboardChunkPlaintext, lane: EnvelopeLane) async throws
    func sendCancel(_ cancel: ClipboardCancelData, lane: EnvelopeLane) async throws
    func sendConflict(_ conflict: ClipboardConflictData, lane: EnvelopeLane) async throws
    func reply(to requestId: String, with ack: Ack, lane: EnvelopeLane) async throws
}

extension ClipboardPeer {
    /// Gọi nhanh với lane mặc định `.control` (0.4.7 bulk rule 2: "the default is control").
    public func sendPush(_ push: ClipboardPushData) async throws -> any AckWaiting {
        try await sendPush(push, lane: .control)
    }
    public func sendChunk(_ chunk: ClipboardChunkPlaintext) async throws {
        try await sendChunk(chunk, lane: .control)
    }
    public func sendCancel(_ cancel: ClipboardCancelData) async throws {
        try await sendCancel(cancel, lane: .control)
    }
    public func sendConflict(_ conflict: ClipboardConflictData) async throws {
        try await sendConflict(conflict, lane: .control)
    }
    public func reply(to requestId: String, with ack: Ack) async throws {
        try await reply(to: requestId, with: ack, lane: .control)
    }
}

/// The current control session as the clipboard peer.
public struct SessionClipboardPeer: ClipboardPeer {
    let session: ControlSession

    public init(session: ControlSession) {
        self.session = session
    }

    public func sendPush(_ push: ClipboardPushData, lane: EnvelopeLane) async throws -> any AckWaiting {
        try await session.sendRequest(.clipboard, op: ClipboardOp.push.rawValue, data: push, lane: lane)
    }

    public func sendChunk(_ chunk: ClipboardChunkPlaintext, lane: EnvelopeLane) async throws {
        try await session.sendBinary(.clipboard, plaintext: try chunk.encoded(), lane: lane)
    }

    public func sendCancel(_ cancel: ClipboardCancelData, lane: EnvelopeLane) async throws {
        try await session.send(.clipboard, op: ClipboardOp.cancel.rawValue, data: cancel, lane: lane)
    }

    public func sendConflict(_ conflict: ClipboardConflictData, lane: EnvelopeLane) async throws {
        try await session.send(.clipboard, op: ClipboardOp.conflict.rawValue, data: conflict, lane: lane)
    }

    public func reply(to requestId: String, with ack: Ack, lane: EnvelopeLane) async throws {
        try await session.reply(to: requestId, with: ack, lane: lane)
    }
}
