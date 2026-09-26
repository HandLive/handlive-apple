import Foundation

/// The HandLive fields of an APNs alert push (0.4.4, CONN-04 API 4): `p` is the `pair_id`, `hl` the Base64 of an
/// envelope whose payload is sealed with `K_push` (the relay copies `env_b64` of `POST /v1/push` into it).
public struct PushAlertFields: Equatable, Sendable {
    /// `env_b64` ≤ 3,000 bytes (CONN-04 API 2); a larger `hl` is not ours.
    public static let maxEnvelopeB64Bytes = 3000

    public let pairId: String
    public let envelope: Envelope

    public init(pairId: String, envelope: Envelope) {
        self.pairId = pairId
        self.envelope = envelope
    }

    /// Reads `p` and `hl` from a notification's `userInfo`; `nil` when they are absent or malformed (the extension
    /// then keeps the generic content, CONN-04 E5).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let pairId = userInfo["p"] as? String, HLUUID.isCanonical(pairId),
              let hl = userInfo["hl"] as? String, hl.utf8.count <= Self.maxEnvelopeB64Bytes,
              let json = try? Base64Coding.decodeB64(hl),
              let envelope = try? Envelope.parse(json)
        else { return nil }
        self.init(pairId: pairId, envelope: envelope)
    }
}
