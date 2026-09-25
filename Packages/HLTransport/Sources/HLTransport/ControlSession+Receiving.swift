import Foundation
import HLProtocol

extension ControlSession {
    /// Ops that expect an `ack` (0.7.1 "Ack" column); an unhandled one is answered `UNSUPPORTED_TYPE`.
    static let requestOps: Set<String> = [
        "pair/revoke", "session/rekey", "ping/ping", "clipboard/push", "sms/sync", "sms/history", "sms/send",
        "call_event/action", "call_event/log_sync", "call_audio/open", "call_audio/close", "camera/start",
        "camera/stop", "camera/config",
    ]

    func receiveLoop() async {
        while ending == nil {
            let message: ChannelMessage
            do {
                message = try await channel.receive()
            } catch let closed as ChannelClosed {
                await end(.peerClosed(closed.local ? nil : closed.code), closing: nil)
                return
            } catch {
                return // cancelled: the session is ending
            }
            guard case .text(let text) = message else { continue } // HL frames belong on /v1/stream/*
            await handle(text)
        }
    }

    private func handle(_ text: String) async {
        // Unknown `type` from a newer peer, or a malformed frame: nothing to answer (0.5.1 rules 3, 6).
        guard let envelope = try? Envelope.parse(Data(text.utf8)) else { return }
        switch recentIDs.check(envelope.id, now: .now) {
        case .duplicate(let ackWire):
            if let ackWire { try? await channel.send(.text(ackWire)) }
            return
        case .new:
            break
        }
        guard let plaintext = try? cipher?.open(envelope, now: .now) else {
            await end(.decryptFailed, closing: .badRequest) // DECRYPT_FAILED → 4400, reconnect (CONN-02 E5)
            return
        }
        if envelope.type == .clipboard, ClipboardChunkPlaintext.isBinaryChunk(plaintext) {
            eventSink.yield(.message(IncomingEnvelope(id: envelope.id, type: envelope.type, ts: envelope.ts,
                                                      body: .binary(plaintext))))
        } else if envelope.type == .ack {
            if let ack = try? Ack.parse(plaintext) {
                // Switch keys here, before reading the next envelope, which may already use the new key.
                if outgoingRekey?.pending.requestId == ack.re { await completeRekey(requestId: ack.re, .success(ack)) }
                pendingAcks.removeValue(forKey: ack.re)?.resolve(.success(ack))
            }
        } else if let payload = try? Payload.parse(plaintext) {
            await dispatch(envelope, payload)
        }
        startRekeyIfNeeded()
    }

    private func dispatch(_ envelope: Envelope, _ payload: Payload) async {
        switch (envelope.type, payload.op) {
        case (.session, SessionOp.rekey.rawValue):
            await answerRekey(envelope, payload)
        case (.session, SessionOp.bye.rawValue):
            let reason = (try? payload.decodeData(as: SessionByeData.self))?.reason ?? .unrecognized
            await end(.peerBye(reason), closing: .normal)
        case (.capability, CapabilityOp.update.rawValue), (.capability, CapabilityOp.hello.rawValue):
            if let capability = try? payload.decodeData(as: CapabilityData.self) {
                peerCapability = capability
                eventSink.yield(.capabilityUpdated(capability))
            }
        case (.pair, "revoke"):
            await answerRevoke(envelope, payload)
        case (.ping, "ping"):
            try? await reply(to: envelope.id, with: .success(re: envelope.id, data: payload.data))
        default:
            if configuration.handledTypes.contains(envelope.type) {
                eventSink.yield(.message(IncomingEnvelope(id: envelope.id, type: envelope.type, ts: envelope.ts,
                                                          body: .json(payload))))
            } else if Self.requestOps.contains("\(envelope.type.rawValue)/\(payload.op)") {
                let error = AckError(code: .unsupportedType, message: "unsupported \(envelope.type.rawValue)")
                try? await reply(to: envelope.id, with: .failure(re: envelope.id, error: error))
            }
        }
    }

    /// `pair/revoke` (PAIR-03 API 1): the `ack` goes out before any key is deleted; then the app cleans up.
    private func answerRevoke(_ envelope: Envelope, _ payload: Payload) async {
        guard (try? payload.decodeData(as: PairRevokeData.self))?.pairId == pair.pairId else {
            let error = AckError(code: .badRequest, message: "pair_id does not match the session")
            try? await reply(to: envelope.id, with: .failure(re: envelope.id, error: error))
            return
        }
        try? await reply(to: envelope.id, with: .success(re: envelope.id))
        eventSink.yield(.pairRevoked)
    }
}
