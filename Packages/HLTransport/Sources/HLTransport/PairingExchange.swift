import Foundation
import HLCrypto
import HLProtocol

/// The client side of one `/v1/pair` connection (PAIR-01 steps 9–11, A4–A5; API 2–6): `pair/hello` → check
/// `pair/offer` (MAC, `device_id`, TLS binding) → `pair/confirm` → check `pair/done` → close 1000. A check that
/// fails sends `pair/error` and closes; `AUTH_FAILED` never says which check failed. Nothing is stored here.
public struct PairingExchange: Sendable {
    public let identity: PairingIdentity
    public let credential: PairingCredential
    /// Wait for `pair/offer`: short for a QR code; with a PIN the phone answers only once the user typed it.
    public let offerTimeout: Duration
    /// Wait for `pair/done` after `pair/confirm`.
    public let doneTimeout: Duration
    /// `K_pin` parameters (0.6.2); tests use smaller ones.
    public var pinParameters = Argon2id.Parameters.pairingPIN

    public init(identity: PairingIdentity, credential: PairingCredential, offerTimeout: Duration,
                doneTimeout: Duration = TransportConstants.requestTimeout) {
        self.identity = identity
        self.credential = credential
        self.offerTimeout = offerTimeout
        self.doneTimeout = doneTimeout
    }

    /// Runs the exchange on an open channel. `certificateSHA256` is the certificate of this connection on the LAN
    /// (step 10), `nil` through the relay. Throws `PairingFailure`.
    public func run(over channel: any MessageChannel, certificateSHA256: Data?,
                    now: @escaping @Sendable () -> Int64 = { HLUUID.currentTimeMs() }) async throws -> PairingResult {
        let link = PairingLink(channel: channel, now: now)
        do {
            let clientNonce = PairingCodes.newNonce()
            try await link.send(.hello, hello(nonce: clientNonce))
            let offer = try await link.receive(.offer, as: PairOfferData.self, timeout: offerTimeout)
            let accepted = try await check(offer, clientNonce: clientNonce, certificateSHA256: certificateSHA256)
            let confirm = try accepted.confirm(identity: identity, createdAt: now())
            try await link.send(.confirm, confirm.data)
            let done = try await link.receive(.done, as: PairDoneData.self, timeout: doneTimeout)
            let result = try accepted.finish(done, confirm: confirm, identity: identity)
            await channel.close(code: .normal)
            return result
        } catch let refusal as PairingRefusal {
            await link.refuse(refusal)
            throw refusal.failure
        } catch let failure as PairingFailure {
            await channel.close(code: .normal)
            throw failure
        } catch {
            await channel.close(code: .normal)
            throw PairingFailure.disconnected
        }
    }

    private func hello(nonce: Data) -> PairHelloData {
        PairHelloData(mode: credential.mode, deviceId: identity.deviceId, nonce: Base64Coding.encodeB64u(nonce),
                      name: identity.name, platform: identity.platform, model: identity.model,
                      ikSigPub: Base64Coding.encodeB64u(identity.signingPublicKey),
                      ikDhPub: Base64Coding.encodeB64u(identity.dhPublicKey))
    }

    /// API 3 logic 3: `mac` → `device_id` matches `ik_sig_pub` → (LAN) `tls_sha256` is this connection's certificate.
    private func check(_ offer: PairOfferData, clientNonce: Data,
                       certificateSHA256: Data?) async throws -> AcceptedOffer {
        guard let fields = OfferFields(offer) else { throw PairingRefusal.authFailed }
        let secret: Data
        switch credential {
        case .qr(let pairingSecret):
            secret = pairingSecret
        case .pin(let pin, _):
            // Argon2id, 64 MiB: off the caller's executor.
            secret = await Task.detached(priority: .userInitiated) { [pinParameters] in
                PairingAuthDerivation.pinKey(pin: pin, clientNonce: clientNonce, serverNonce: fields.nonce,
                                             parameters: pinParameters)
            }.value
        }
        let client = PairingParty(deviceId: identity.deviceId, nonce: clientNonce,
                                  signingPublicKey: identity.signingPublicKey, dhPublicKey: identity.dhPublicKey,
                                  name: identity.name)
        let server = PairingParty(deviceId: offer.deviceId, nonce: fields.nonce, signingPublicKey: fields.signingKey,
                                  dhPublicKey: fields.dhKey, name: offer.name)
        guard let transcript = try? PairingAuthDerivation.offerTranscript(client: client, server: server,
                                                                          tlsSHA256: fields.tlsSHA256)
        else { throw PairingRefusal.authFailed }
        let authKey = PairingAuthDerivation.authKey(secret: secret, clientNonce: clientNonce, serverNonce: fields.nonce)
        let expected = PairingAuthDerivation.offerMac(authKey: authKey, transcript: transcript)
        guard HMACSHA256.constantTimeEquals(expected, fields.mac) else {
            if case .pin(_, let attemptsLeft) = credential { throw PairingRefusal.wrongPIN(attemptsLeft: attemptsLeft - 1) }
            throw PairingRefusal.authFailed
        }
        guard DeviceIdentity.matches(deviceId: offer.deviceId, signingPublicKey: fields.signingKey),
              certificateSHA256.map({ HMACSHA256.constantTimeEquals($0, fields.tlsSHA256) }) ?? true,
              let prk = try? PairingKeyDerivation.prk(ownDHPrivateKey: identity.dhPrivateKey,
                                                      peerDHPublicKey: fields.dhKey, pairingSecret: secret,
                                                      ownDeviceId: identity.deviceId, peerDeviceId: offer.deviceId)
        else { throw PairingRefusal.authFailed }
        return AcceptedOffer(offer: offer, fields: fields, authKey: authKey, transcript: transcript, prk: prk)
    }
}

/// `pair/error` this side sends before closing: `AUTH_FAILED`, or `PIN_INVALID` with the attempts left.
struct PairingRefusal: Error {
    let code: ErrorCode
    let attemptsLeft: Int?
    let failure: PairingFailure

    static let authFailed = PairingRefusal(code: .authFailed, attemptsLeft: nil, failure: .authFailed)

    static func wrongPIN(attemptsLeft: Int) -> PairingRefusal {
        let left = max(attemptsLeft, 0)
        return PairingRefusal(code: .pinInvalid, attemptsLeft: left, failure: .pinInvalid(attemptsLeft: left))
    }

    /// English diagnostics only (0.12.4), never which check failed.
    var message: String {
        code == .pinInvalid ? "PIN does not match" : "Pairing authentication failed"
    }
}
