import Foundation
import HLCrypto
import HLProtocol

/// The byte fields of `pair/offer`, decoded with their exact sizes; `nil` for any malformed field.
struct OfferFields: Sendable {
    let nonce: Data
    let signingKey: Data
    let dhKey: Data
    let tlsSHA256: Data
    let mac: Data

    init?(_ offer: PairOfferData) {
        guard let nonce = Self.bytes(offer.nonce), let signingKey = Self.bytes(offer.ikSigPub),
              let dhKey = Self.bytes(offer.ikDhPub), let tls = Self.bytes(offer.tlsSha256),
              let mac = Self.bytes(offer.mac), HLUUID.isCanonical(offer.deviceId)
        else { return nil }
        self.nonce = nonce
        self.signingKey = signingKey
        self.dhKey = dhKey
        tlsSHA256 = tls
        self.mac = mac
    }

    static func bytes(_ text: String, count: Int = 32) -> Data? {
        guard let data = try? Base64Coding.decodeB64u(text), data.count == count else { return nil }
        return data
    }
}

/// `pair/confirm` as sent, with the attestation it signs.
struct SentConfirm: Sendable {
    let data: PairConfirmData
    let attestation: Data
    let signature: Data
}

/// An offer whose MAC, `device_id` and TLS binding checked out, with `K_pa`, `T_offer` and `PRK`.
struct AcceptedOffer: Sendable {
    let offer: PairOfferData
    let fields: OfferFields
    let authKey: Data
    let transcript: Data
    let prk: Data

    /// API 4: a UUIDv4 `pair_id`, the attestation signed with `ik_sig`, `prk_check` and the MAC over all of it.
    func confirm(identity: PairingIdentity, createdAt: Int64, pairId: String) throws -> SentConfirm {
        let attestation = try PairingAuthDerivation.attestation(PairingAttestationFields(
            pairId: pairId, androidDeviceId: offer.deviceId, clientDeviceId: identity.deviceId,
            androidSigningKey: fields.signingKey, clientSigningKey: identity.signingPublicKey, createdAt: createdAt))
        let signature = try Ed25519.sign(attestation, seed: identity.signingSeed)
        let check = try PairingAuthDerivation.prkCheck(prk: prk, pairId: pairId, role: .client)
        let mac = try PairingAuthDerivation.confirmMac(authKey: authKey, transcript: transcript, pairId: pairId,
                                                       createdAt: createdAt, clientSignature: signature)
        let data = PairConfirmData(pairId: pairId, createdAt: createdAt, sig: Base64Coding.encodeB64u(signature),
                                   prkCheck: Base64Coding.encodeB64u(check), mac: Base64Coding.encodeB64u(mac))
        return SentConfirm(data: data, attestation: attestation, signature: signature)
    }

    /// API 5 logic 1: `mac`, `prk_check`, then the phone's signature over the same attestation (strict Ed25519).
    func finish(_ done: PairDoneData, confirm: SentConfirm, identity: PairingIdentity) throws -> PairingResult {
        let pairId = confirm.data.pairId
        guard let signature = OfferFields.bytes(done.sig, count: 64), let check = OfferFields.bytes(done.prkCheck),
              let mac = OfferFields.bytes(done.mac),
              let expectedMac = try? PairingAuthDerivation.doneMac(authKey: authKey, pairId: pairId,
                                                                   serverSignature: signature),
              let expectedCheck = try? PairingAuthDerivation.prkCheck(prk: prk, pairId: pairId, role: .server)
        else { throw PairingRefusal.authFailed(.malformed) }
        guard HMACSHA256.constantTimeEquals(expectedMac, mac) else { throw PairingRefusal.authFailed(.doneMac) }
        guard HMACSHA256.constantTimeEquals(expectedCheck, check) else { throw PairingRefusal.authFailed(.prkCheckS) }
        guard Ed25519.verify(signature, message: confirm.attestation, publicKey: fields.signingKey) else {
            throw PairingRefusal.authFailed(.sigS)
        }
        return PairingResult(pairId: pairId, createdAt: confirm.data.createdAt, phoneDeviceId: offer.deviceId,
                             phoneName: offer.name, phoneModel: offer.model, phoneOSVersion: offer.osVersion,
                             phoneSigningPublicKey: fields.signingKey, phoneDHPublicKey: fields.dhKey,
                             certificateSHA256: fields.tlsSHA256, attestation: confirm.attestation,
                             signatureSelf: confirm.signature, signaturePeer: signature, prk: prk)
    }
}
