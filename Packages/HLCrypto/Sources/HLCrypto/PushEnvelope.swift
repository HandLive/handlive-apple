import Foundation
import HLProtocol

/// Envelopes that travel inside an APNs alert (0.4.4, CONN-04 API 2 and 4): the phone seals them with `K_push` =
/// HKDF(`PRK`, info `"handlive/v1/push"`, L = 32) instead of a session key, because a suspended iPhone has no session.
/// The Notification Service Extension opens them while the device is unlocked (C3).
public enum PushEnvelope {
    public static let info = "handlive/v1/push"
    /// Older envelopes are not shown again (CONN-04 E7).
    public static let maxAgeMs: Int64 = 24 * 3600 * 1000

    public enum OpenError: Error, Equatable, Sendable {
        /// `ts` more than 24 h before now (CONN-04 E7).
        case expired
        /// The AEAD refused the payload: wrong pair, wrong key or tampering (CONN-04 E5).
        case undecryptable
    }

    /// `K_push` of a pair.
    public static func key(prk: Data) throws -> Data {
        try Bytes.require(prk, count: 32)
        return HKDFSHA256.derive(ikm: prk, info: info, length: 32)
    }

    /// Seals a payload plaintext the way the phone does (step 5b); used by tests and fakes.
    public static func seal(type: MessageType, plaintext: Data, prk: Data, id: String = HLUUID.v7(),
                            ts: Int64 = HLUUID.currentTimeMs()) throws -> Envelope {
        try EnvelopeCipher.seal(type: type, plaintext: plaintext, key: key(prk: prk), id: id, ts: ts)
    }

    /// Opens the envelope of the `hl` field: checks its age first, then decrypts with `K_push`.
    public static func open(_ envelope: Envelope, prk: Data, nowMs: Int64 = HLUUID.currentTimeMs()) throws -> Data {
        guard nowMs - envelope.ts <= maxAgeMs else { throw OpenError.expired }
        do {
            return try EnvelopeCipher.open(envelope, key: key(prk: prk))
        } catch {
            throw OpenError.undecryptable
        }
    }
}
