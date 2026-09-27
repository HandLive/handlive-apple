import Foundation
import HLProtocol

/// What the relay connection reports besides forwarded envelopes (0.7.3).
public enum RelayLinkEvent: Sendable, Equatable {
    case presence(pairId: String, peerDeviceId: String, online: Bool)
    case pairRevoked(pairId: String, by: String)
    case error(code: RelayErrorCode, to: String?)
    case rendezvousJoined(rvId: String, peerPresent: Bool)
    /// The connection to the relay ended; every channel through it is closed.
    case closed
}

/// One connection to `/v1/relay` (CONN-03 API 4–6): routes forwarded envelopes to a virtual channel per peer, keeps
/// the latest `presence` of each pair, answers nothing itself and pings the relay every `WS_PING_INTERVAL`.
public actor RelayLink {
    public nonisolated let events: AsyncStream<RelayLinkEvent>
    let eventSink: AsyncStream<RelayLinkEvent>.Continuation
    let socket: any MessageChannel
    let pingInterval: Duration
    let pongTimeout: Duration
    var peers: [String: RelayPeerChannel] = [:]
    var rendezvous: [String: RelayRendezvousChannel] = [:]
    var presenceByPair: [String: Bool] = [:]
    var loops: [Task<Void, Never>] = []
    public private(set) var isClosed = false

    public init(socket: any MessageChannel, pingInterval: Duration = TransportConstants.pingInterval,
                pongTimeout: Duration = TransportConstants.pongTimeout) {
        self.socket = socket
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        (events, eventSink) = AsyncStream.makeStream(of: RelayLinkEvent.self)
    }

    public func start() {
        guard loops.isEmpty, !isClosed else { return }
        loops.append(Task { await self.receiveLoop() })
        loops.append(Task { await self.keepAliveLoop() })
    }

    /// Latest `presence.online` of a pair; `nil` until the relay said something about it.
    public func presence(pairId: String) -> Bool? {
        presenceByPair[pairId]
    }

    /// Virtual channel to a peer device; an older channel to the same peer is closed first.
    public func channel(to deviceId: String) async -> RelayPeerChannel {
        await peers[deviceId]?.close(code: .normal)
        let channel = RelayPeerChannel(peerDeviceId: deviceId, link: self)
        if isClosed { channel.remoteClosed("relay closed") } else { peers[deviceId] = channel }
        return channel
    }

    /// Joins a pairing rendezvous (`rv_join`, PAIR-01 API 7) and returns its channel.
    public func joinRendezvous(rvId: String) async throws -> RelayRendezvousChannel {
        let channel = RelayRendezvousChannel(rvId: rvId, link: self)
        rendezvous[rvId] = channel
        try await sendText(try RelayFrame.rendezvousJoin(rvId: rvId))
        return channel
    }

    /// Ends the relay connection (close 1000) and every channel through it.
    public func close() async {
        await finish(closing: true)
    }

    // MARK: - Used by the channels

    func sendText(_ text: String) async throws {
        guard !isClosed else { throw ChannelClosed(code: nil, detail: "relay closed", local: true) }
        try await socket.send(.text(text))
    }

    func pingSocket(timeout: Duration) async throws {
        try await socket.ping(payload: Data(count: 8), timeout: timeout)
    }

    func detach(peer channel: RelayPeerChannel) {
        if peers[channel.peerDeviceId] === channel { peers[channel.peerDeviceId] = nil }
    }

    func detach(rendezvous channel: RelayRendezvousChannel) {
        if rendezvous[channel.rvId] === channel { rendezvous[channel.rvId] = nil }
    }

    // MARK: - Loops

    private func receiveLoop() async {
        while !isClosed {
            let message: ChannelMessage
            do {
                message = try await socket.receive()
            } catch is CancellationError {
                return
            } catch {
                await finish(closing: false)
                return
            }
            guard case .text(let text) = message, let inbound = try? RelayFrame.parse(text) else { continue }
            route(inbound)
        }
    }

    private func route(_ inbound: RelayInbound) {
        switch inbound {
        case .forward(let from, let envelope):
            peers[from]?.deliver(envelope)
        case .control(.presence(let pairId, let peer, let online)):
            presenceByPair[pairId] = online
            eventSink.yield(.presence(pairId: pairId, peerDeviceId: peer, online: online))
        case .control(.error(let code, _, let to)):
            if code == .notConnected, let to, let channel = peers[to] {
                channel.remoteClosed("peer not connected") // E8
                peers[to] = nil
            }
            eventSink.yield(.error(code: code, to: to))
        case .control(.pairRevoked(let pairId, let by)):
            eventSink.yield(.pairRevoked(pairId: pairId, by: by))
        case .control(.rendezvousJoined(let rvId, let present)):
            rendezvous[rvId]?.joined(peerPresent: present)
            eventSink.yield(.rendezvousJoined(rvId: rvId, peerPresent: present))
        case .control(.rendezvousMessage(let rvId, let envelope)):
            rendezvous[rvId]?.deliver(envelope)
        case .control(.unknown):
            break
        }
    }

    private func keepAliveLoop() async {
        while !isClosed {
            do {
                try await Task.sleep(for: pingInterval)
                try await socket.ping(payload: Data(count: 8), timeout: pongTimeout)
            } catch is CancellationError {
                return
            } catch {
                await finish(closing: true)
                return
            }
        }
    }

    private func finish(closing: Bool) async {
        guard !isClosed else { return }
        isClosed = true
        loops.forEach { $0.cancel() }
        loops.removeAll()
        if closing { await socket.close(code: .normal) }
        for channel in peers.values { channel.remoteClosed("relay closed") }
        for channel in rendezvous.values { channel.remoteClosed("relay closed") }
        peers.removeAll()
        rendezvous.removeAll()
        eventSink.yield(.closed)
        eventSink.finish()
    }
}
