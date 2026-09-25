import Foundation
import HLCrypto
import HLProtocol

/// A client session on `/v1/ctl` (CONN-01 steps 6–9, CONN-02): session handshake, `capability/hello`,
/// encrypted envelopes with `ack` tracking and de-duplication, rekey, WebSocket keepalive and a clean end.
public actor ControlSession {
    /// Everything the session reports; finishes after `.ended`.
    public nonisolated let events: AsyncStream<SessionEvent>
    /// Route the channel took (Phase 1: always the LAN).
    public nonisolated let route: ConnectionRoute
    /// Capability of the phone: from its `capability/hello`, replaced by each `capability/update`.
    public internal(set) var peerCapability: CapabilityData?

    let eventSink: AsyncStream<SessionEvent>.Continuation
    let channel: any MessageChannel
    let pair: PairContext
    let configuration: SessionConfiguration
    var cipher: SessionCipher?
    var pendingAcks: [String: PendingAck] = [:]
    var recentIDs: RecentEnvelopeIDs
    var ending: SessionEnd?
    var loops: [Task<Void, Never>] = []
    var outgoingRekey: OutgoingRekey?

    init(channel: any MessageChannel, pair: PairContext, route: ConnectionRoute, configuration: SessionConfiguration) {
        self.channel = channel
        self.pair = pair
        self.route = route
        self.configuration = configuration
        recentIDs = RecentEnvelopeIDs(window: configuration.dedupWindow, capacity: configuration.dedupCapacity)
        (events, eventSink) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    /// Runs the handshake on an open channel and starts the session. Throws `SessionEstablishError`; the channel
    /// is closed on failure.
    public static func establish(over channel: any MessageChannel, pair: PairContext, localCapability: CapabilityData,
                                 route: ConnectionRoute, configuration: SessionConfiguration = SessionConfiguration())
    async throws -> ControlSession {
        let session = ControlSession(channel: channel, pair: pair, route: route, configuration: configuration)
        try await session.handshake(localCapability: localCapability)
        await session.startLoops()
        return session
    }

    // MARK: - Sending

    /// Sends an event (no `ack`).
    public func send<Body: Encodable & Sendable>(_ type: MessageType, op: String, data: Body) async throws {
        try await transmit(try seal(type, plaintext: try encode(op: op, data: data)))
    }

    /// Sends a request and returns the handle of its `ack`; the caller decides when to start waiting.
    public func sendRequest<Body: Encodable & Sendable>(_ type: MessageType, op: String,
                                                        data: Body) async throws -> PendingAck {
        let envelope = try seal(type, plaintext: try encode(op: op, data: data))
        pendingAcks = pendingAcks.filter { !$0.value.isResolved } // drop requests that timed out
        let pending = PendingAck(requestId: envelope.id)
        pendingAcks[envelope.id] = pending
        do {
            try await transmit(envelope)
        } catch {
            pendingAcks[envelope.id] = nil
            throw error
        }
        return pending
    }

    /// Sends a request and waits for its `ack` (`REQUEST_TIMEOUT` unless given).
    public func request<Body: Encodable & Sendable>(_ type: MessageType, op: String, data: Body,
                                                    timeout: Duration? = nil) async throws -> Ack {
        try await sendRequest(type, op: op, data: data).response(timeout: timeout ?? configuration.requestTimeout)
    }

    /// Sends a binary plaintext envelope (`clipboard/chunk`, 0.5.1).
    public func sendBinary(_ type: MessageType, plaintext: Data) async throws {
        try await transmit(try seal(type, plaintext: plaintext))
    }

    /// Answers a request of the phone; the `ack` is kept for repeats of the same `id` (0.5.1 rule 2).
    public func reply(to requestId: String, with ack: Ack) async throws {
        guard let plaintext = try? ack.encoded() else { throw SessionError.encoding }
        let envelope = try seal(.ack, plaintext: plaintext)
        recentIDs.remember(ackWire: envelope.wireString(), for: requestId)
        try await transmit(envelope)
    }

    /// Sends `capability/update`: a full snapshot of this device's capability (SET-02 API 1).
    public func updateCapability(_ capability: CapabilityData) async throws {
        try await send(.capability, op: CapabilityOp.update.rawValue, data: capability)
    }

    /// Ends the session from this side: `session/bye` when a reason is given (shutdown, sleep, revoked —
    /// CONN-02 step 8, PAIR-03 API 2), then close 1000.
    public func close(bye reason: SessionByeData.Reason?) async {
        guard ending == nil else { return }
        if let reason, cipher != nil {
            try? await send(.session, op: SessionOp.bye.rawValue, data: SessionByeData(reason: reason))
        }
        await end(.local(.normal), closing: .normal)
    }

    /// Pings at once with a short deadline; a dead link ends the session. Used after the default network changes,
    /// so reconnecting does not wait for the next keepalive (CONN-02 step 5, reconnect < 3 s).
    public func probe(timeout: Duration) async {
        guard ending == nil else { return }
        do {
            try await channel.ping(payload: Data(count: 8), timeout: timeout)
        } catch {
            await end(.pongTimeout, closing: .normal)
        }
    }

    // MARK: - Internals shared by the extensions

    func encode<Body: Encodable>(op: String, data: Body) throws -> Data {
        guard let plaintext = try? TypedPayloadEncoder.encode(op: op, data: data) else { throw SessionError.encoding }
        return plaintext
    }

    func seal(_ type: MessageType, plaintext: Data) throws -> Envelope {
        guard ending == nil, cipher != nil else { throw SessionError.ended }
        guard let envelope = try? cipher?.seal(type: type, plaintext: plaintext) else { throw SessionError.encoding }
        return envelope
    }

    func transmit(_ envelope: Envelope) async throws {
        do {
            try await channel.send(.text(envelope.wireString()))
        } catch {
            throw SessionError.ended
        }
        startRekeyIfNeeded()
    }

    /// Ends the session once: fails pending requests, stops the loops, closes the channel when asked, reports why.
    func end(_ reason: SessionEnd, closing code: CloseCode?) async {
        guard ending == nil else { return }
        ending = reason
        for pending in pendingAcks.values { pending.resolve(.failure(SessionError.ended)) }
        pendingAcks.removeAll()
        outgoingRekey = nil
        loops.forEach { $0.cancel() }
        loops.removeAll()
        if let code { await channel.close(code: code) }
        eventSink.yield(.ended(reason))
        eventSink.finish()
    }

    private func startLoops() {
        loops.append(Task { await self.receiveLoop() })
        loops.append(Task { await self.keepAliveLoop() })
    }

    /// WebSocket ping every `WS_PING_INTERVAL` with an 8-byte counter; no pong within `PONG_TIMEOUT` → lost.
    private func keepAliveLoop() async {
        var counter: UInt64 = 0
        while ending == nil {
            do {
                try await Task.sleep(for: configuration.pingInterval)
            } catch {
                return
            }
            counter += 1
            let payload = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
            do {
                try await channel.ping(payload: payload, timeout: configuration.pongTimeout)
            } catch {
                await end(.pongTimeout, closing: .normal)
                return
            }
        }
    }
}

/// Encodes `{"op", "data"}` for any `Encodable` body.
enum TypedPayloadEncoder {
    private struct Body<Value: Encodable>: Encodable {
        let op: String
        let data: Value
    }

    static func encode<Value: Encodable>(op: String, data: Value) throws -> Data {
        try HLJSON.encode(Body(op: op, data: data))
    }
}
