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
    func sendPush(_ push: ClipboardPushData) async throws -> any AckWaiting
    func sendChunk(_ chunk: ClipboardChunkPlaintext) async throws
    func sendCancel(_ cancel: ClipboardCancelData) async throws
    func sendConflict(_ conflict: ClipboardConflictData) async throws
    func reply(to requestId: String, with ack: Ack) async throws
}

/// The current control session as the clipboard peer.
public struct SessionClipboardPeer: ClipboardPeer {
    let session: ControlSession

    public init(session: ControlSession) {
        self.session = session
    }

    public func sendPush(_ push: ClipboardPushData) async throws -> any AckWaiting {
        try await session.sendRequest(.clipboard, op: ClipboardOp.push.rawValue, data: push)
    }

    public func sendChunk(_ chunk: ClipboardChunkPlaintext) async throws {
        try await session.sendBinary(.clipboard, plaintext: try chunk.encoded())
    }

    public func sendCancel(_ cancel: ClipboardCancelData) async throws {
        try await session.send(.clipboard, op: ClipboardOp.cancel.rawValue, data: cancel)
    }

    public func sendConflict(_ conflict: ClipboardConflictData) async throws {
        try await session.send(.clipboard, op: ClipboardOp.conflict.rawValue, data: conflict)
    }

    public func reply(to requestId: String, with ack: Ack) async throws {
        try await session.reply(to: requestId, with: ack)
    }
}
