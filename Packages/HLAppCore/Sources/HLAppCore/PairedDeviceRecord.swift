import Foundation
import HLCrypto
import HLProtocol
import HLTransport

/// The client side of a pair (0.9.3 `paired_device`); `PRK` stays in the Keychain under account `pair_id`.
public struct PairedDeviceRecord: Codable, Sendable, Equatable {
    public var pairId: String
    public var peerDeviceId: String
    public var peerName: String
    public var peerModel: String?
    public var peerSigningPublicKey: Data
    public var peerKeyAgreementPublicKey: Data
    /// Pinned SHA-256 of the phone's TLS certificate.
    public var peerCertificateSHA256: Data
    public var attestation: Data
    public var signatureSelf: Data
    public var signaturePeer: Data
    /// Last capability of the phone (`features_json`).
    public var peerCapability: CapabilityData?
    public var lastHost: String?
    public var lastPort: UInt16?
    public var relayRegistered: Bool
    public var createdAt: Int64
    public var lastSeenAt: Int64?
    /// Tombstone (PAIR-03 E3): keys and data gone, relay revocation pending.
    public var revokedAt: Int64?

    public init(pairId: String, peerDeviceId: String, peerName: String, peerModel: String?, peerSigningPublicKey: Data,
                peerKeyAgreementPublicKey: Data, peerCertificateSHA256: Data, attestation: Data, signatureSelf: Data,
                signaturePeer: Data, createdAt: Int64) {
        self.pairId = pairId
        self.peerDeviceId = peerDeviceId
        self.peerName = peerName
        self.peerModel = peerModel
        self.peerSigningPublicKey = peerSigningPublicKey
        self.peerKeyAgreementPublicKey = peerKeyAgreementPublicKey
        self.peerCertificateSHA256 = peerCertificateSHA256
        self.attestation = attestation
        self.signatureSelf = signatureSelf
        self.signaturePeer = signaturePeer
        relayRegistered = false
        self.createdAt = createdAt
    }

    /// "Security Code": the first 8 hex digits of SHA-256(`attestation`), shown as two groups ("7F3A 9C21"),
    /// the same on both devices of the pair (PAIR-02 field 10).
    public var securityCode: String {
        let hex = HMACSHA256.sha256(attestation).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4)) \(hex.suffix(4))"
    }

    /// What the connection manager needs, with the `PRK` loaded from the Keychain.
    public func pairedPhone(clientDeviceId: String, prk: Data) -> PairedPhone {
        PairedPhone(pair: PairContext(pairId: pairId, clientDeviceId: clientDeviceId, serverDeviceId: peerDeviceId, prk: prk),
                    certificateSHA256: peerCertificateSHA256, lastHost: lastHost, lastPort: lastPort)
    }
}
