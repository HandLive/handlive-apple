import Foundation
import HLCrypto
import HLProtocol

/// A `session/rekey` this side sent and whose `ack` it waits for.
struct OutgoingRekey {
    let epoch: Int32
    let ephemeralPrivateKey: Data
    let nonce: Data
    let pending: PendingAck
}

extension ControlSession {
    /// Starts a rekey after `REKEY_AFTER` (24 h or 10 000 envelopes in one direction), unless one is running.
    func startRekeyIfNeeded() {
        guard ending == nil, outgoingRekey == nil, let cipher,
              cipher.needsRekey(now: .now, maxEnvelopes: configuration.rekeyAfterEnvelopes,
                                maxAge: configuration.rekeyAfterAge)
        else { return }
        let epoch = cipher.epoch + 1
        let privateKey = X25519.generatePrivateKey()
        let nonce = SessionHandshakeCrypto.randomNonce()
        guard let publicKey = try? X25519.publicKey(privateKey: privateKey),
              let envelope = try? seal(.session, plaintext: try encode(op: SessionOp.rekey.rawValue, data: SessionRekeyData(
                  epoch: epoch, eph: Base64Coding.encodeB64u(publicKey), nonce: Base64Coding.encodeB64u(nonce))))
        else { return }
        let pending = PendingAck(requestId: envelope.id)
        pendingAcks[envelope.id] = pending
        outgoingRekey = OutgoingRekey(epoch: epoch, ephemeralPrivateKey: privateKey, nonce: nonce, pending: pending)
        loops.append(Task {
            try? await self.channel.send(.text(envelope.wireString()))
            let outcome: Result<Ack, Error>
            do {
                outcome = .success(try await pending.response(timeout: self.configuration.requestTimeout))
            } catch {
                outcome = .failure(error)
            }
            await self.completeRekey(requestId: envelope.id, outcome)
        })
    }

    /// The initiator switches keys when the `ack` arrives (0.6.3 step 6); no valid `ack` in 10 s → 4410.
    /// Called by the receive loop for the `ack` (in order with the envelopes after it) and by the waiting task
    /// for a timeout; whichever comes second finds nothing to do.
    func completeRekey(requestId: String, _ outcome: Result<Ack, Error>) async {
        // Lost a simultaneous rekey (the other side answered ours away) or the session ended: nothing to do.
        pendingAcks[requestId] = nil
        guard let rekey = outgoingRekey, rekey.pending.requestId == requestId, ending == nil else { return }
        outgoingRekey = nil
        guard case .success(let ack) = outcome, ack.ok,
              let data = try? ack.data.map({ try HLJSON.convert($0, to: SessionRekeyData.self) }),
              data.epoch == rekey.epoch,
              let peerEph = try? Base64Coding.decodeB64u(data.eph),
              let peerNonce = try? Base64Coding.decodeB64u(data.nonce),
              let shared = try? X25519.sharedSecret(privateKey: rekey.ephemeralPrivateKey, peerPublicKey: peerEph),
              let keys = try? cipher?.keys.rekeyed(ephemeralShared: shared, initiatorNonce: rekey.nonce,
                                                    responderNonce: peerNonce)
        else {
            await end(.rekeyFailed, closing: .rekeyFailed)
            return
        }
        cipher?.install(keys, epoch: rekey.epoch, now: .now, grace: configuration.rekeyOldKeyGrace)
    }

    /// Answers the phone's `session/rekey`: `ack` with this side's `{epoch, eph, nonce}` under the old key, then
    /// switch. Simultaneous rekeys: the smaller `device_id` wins and ignores the other request (CONN-02 API 3).
    func answerRekey(_ envelope: Envelope, _ payload: Payload) async {
        guard let cipher else { return }
        if outgoingRekey != nil {
            if Self.clientWinsCollision(client: pair.clientDeviceId, server: pair.serverDeviceId) { return }
            outgoingRekey = nil // lost: our request is dropped, its ack will never come
        }
        let epoch = cipher.epoch + 1
        let privateKey = X25519.generatePrivateKey()
        let nonce = SessionHandshakeCrypto.randomNonce()
        guard let request = try? payload.decodeData(as: SessionRekeyData.self), request.epoch == epoch,
              let peerEph = try? Base64Coding.decodeB64u(request.eph),
              let peerNonce = try? Base64Coding.decodeB64u(request.nonce),
              let publicKey = try? X25519.publicKey(privateKey: privateKey),
              let shared = try? X25519.sharedSecret(privateKey: privateKey, peerPublicKey: peerEph),
              let keys = try? cipher.keys.rekeyed(ephemeralShared: shared, initiatorNonce: peerNonce,
                                                  responderNonce: nonce),
              let ackData = try? HLJSON.convert(from: SessionRekeyData(
                  epoch: epoch, eph: Base64Coding.encodeB64u(publicKey), nonce: Base64Coding.encodeB64u(nonce))),
              let ackPlaintext = try? Ack.success(re: envelope.id, data: ackData).encoded(),
              let ackEnvelope = try? seal(.ack, plaintext: ackPlaintext)
        else {
            let error = AckError(code: .badRequest, message: "invalid rekey request")
            try? await reply(to: envelope.id, with: .failure(re: envelope.id, error: error))
            return
        }
        // The ack is sealed with the old key; everything sent after it uses the new one. NWConnection keeps
        // the order of send calls, so switching before the ack's send completes cannot reorder them.
        self.cipher?.install(keys, epoch: epoch, now: .now, grace: configuration.rekeyOldKeyGrace)
        recentIDs.remember(ackWire: ackEnvelope.wireString(), for: envelope.id)
        try? await channel.send(.text(ackEnvelope.wireString()))
    }

    /// `device_id`s compared as 16 bytes, unsigned (same order as the lowercase uuid strings).
    static func clientWinsCollision(client: String, server: String) -> Bool {
        client < server
    }
}

extension HLJSON {
    /// Any `Encodable` as a `JSONValue` (for `ack.data`).
    static func convert<Value: Encodable>(from value: Value) throws -> JSONValue {
        try decode(JSONValue.self, from: encode(value))
    }
}
