import Foundation
import HLProtocol

/// A `/v1/ctl` session through the relay (CONN-03 step 9): each envelope goes out wrapped as `{"to","env"}` and comes
/// back unwrapped from `{"from","env"}`, so `ControlSession` runs the same handshake and E2E encryption as on the LAN.
/// Pings check the hop to the relay; `ControlSession` adds the end-to-end `ping/ping` on this route.
public final class RelayPeerChannel: MessageChannel, @unchecked Sendable {
    public let peerDeviceId: String
    private let inbox = ChannelInbox()
    private weak var link: RelayLink?

    init(peerDeviceId: String, link: RelayLink) {
        self.peerDeviceId = peerDeviceId
        self.link = link
    }

    public func receive() async throws -> ChannelMessage {
        try await inbox.receive()
    }

    /// Sends an envelope (the wire JSON object of 0.5.1) to the peer.
    public func send(_ message: ChannelMessage) async throws {
        if let reason = inbox.closedReason { throw reason }
        guard case .text(let envelope) = message, envelope.hasPrefix("{"), let link else {
            throw ChannelClosed(code: nil, detail: "not an envelope", local: true)
        }
        try await link.sendText("{\"to\":\"\(peerDeviceId)\",\"env\":\(envelope)}")
    }

    public func ping(payload: Data, timeout: Duration) async throws {
        guard let link, !inbox.isClosed else { throw ChannelClosed(code: nil, detail: "closed", local: true) }
        try await link.pingSocket(timeout: timeout)
    }

    /// Closes this virtual channel only; the relay connection stays for other uses. The peer learns about the end
    /// through `session/bye` (a close code cannot travel through the relay).
    public func close(code: CloseCode) async {
        guard !inbox.isClosed else { return }
        inbox.close(ChannelClosed(code: code, detail: "closed locally", local: true))
        await link?.detach(peer: self)
    }

    func deliver(_ envelope: Envelope) {
        inbox.deliver(.text(envelope.wireString()))
    }

    /// The relay went away, or said the peer is not connected (E8).
    func remoteClosed(_ detail: String) {
        inbox.close(ChannelClosed(code: nil, detail: detail))
    }
}

/// The pairing rendezvous as a channel (PAIR-01 API 7): `pair` envelopes travel inside `rv_msg`.
public final class RelayRendezvousChannel: MessageChannel, @unchecked Sendable {
    public let rvId: String
    private let inbox = ChannelInbox()
    private weak var link: RelayLink?
    private let lock = NSLock()
    private var present = false
    private var presenceWaiters: [CheckedContinuation<Bool, Never>] = []

    init(rvId: String, link: RelayLink) {
        self.rvId = rvId
        self.link = link
    }

    /// Waits until the other member joined (`rv_joined` with `peer_present = true`); `false` once closed.
    public func waitForPeer() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if present || inbox.isClosed {
                let result = present
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                presenceWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public var peerPresent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return present
    }

    public func receive() async throws -> ChannelMessage {
        try await inbox.receive()
    }

    public func send(_ message: ChannelMessage) async throws {
        if let reason = inbox.closedReason { throw reason }
        guard case .text(let text) = message, let link, let envelope = try? Envelope.parse(Data(text.utf8)) else {
            throw ChannelClosed(code: nil, detail: "not an envelope", local: true)
        }
        try await link.sendText(try RelayFrame.rendezvousMessage(rvId: rvId, envelope: envelope))
    }

    public func ping(payload: Data, timeout: Duration) async throws {
        guard let link, !inbox.isClosed else { throw ChannelClosed(code: nil, detail: "closed", local: true) }
        try await link.pingSocket(timeout: timeout)
    }

    public func close(code: CloseCode) async {
        guard !inbox.isClosed else { return }
        inbox.close(ChannelClosed(code: code, detail: "closed locally", local: true))
        resolveWaiters()
        await link?.detach(rendezvous: self)
    }

    func joined(peerPresent: Bool) {
        lock.lock()
        present = present || peerPresent
        lock.unlock()
        if peerPresent { resolveWaiters() }
    }

    func deliver(_ envelope: Envelope) {
        inbox.deliver(.text(envelope.wireString()))
    }

    func remoteClosed(_ detail: String) {
        inbox.close(ChannelClosed(code: nil, detail: detail))
        resolveWaiters()
    }

    private func resolveWaiters() {
        lock.lock()
        let waiters = presenceWaiters
        presenceWaiters.removeAll()
        let result = present
        lock.unlock()
        waiters.forEach { $0.resume(returning: result) }
    }
}
