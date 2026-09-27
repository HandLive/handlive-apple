import Foundation
import HLCrypto
import HLProtocol

/// This Mac/iPhone as `pair/hello` presents it (PAIR-01 API 2), with the private keys the exchange needs.
public struct PairingIdentity: Sendable {
    public let deviceId: String
    /// Device name, already fitted to the QR code (`PairingInvite.fittedName`); the same text goes into `d`,
    /// `pair/hello` and `T_offer`.
    public let name: String
    public let platform: CapabilityData.Platform
    public let model: String?
    public let signingSeed: Data
    public let signingPublicKey: Data
    public let dhPrivateKey: Data
    public let dhPublicKey: Data

    public init(deviceId: String, name: String, platform: CapabilityData.Platform, model: String?, signingSeed: Data,
                signingPublicKey: Data, dhPrivateKey: Data, dhPublicKey: Data) {
        self.deviceId = deviceId
        self.name = name
        self.platform = platform
        self.model = model
        self.signingSeed = signingSeed
        self.signingPublicKey = signingPublicKey
        self.dhPrivateKey = dhPrivateKey
        self.dhPublicKey = dhPublicKey
    }
}

/// What authenticates the exchange: the QR code's `pairing_secret`, or the PIN shown on this device (A1–A5).
public enum PairingCredential: Sendable, Equatable {
    /// With a rendezvous joined on the relay, the QR code carries its `rv` and the phone may pair through it (P2).
    case qr(secret: Data, rendezvous: PairingRendezvous? = nil)
    /// `attemptsLeft` counts this attempt: 3 for a new PIN; a wrong PIN leaves one fewer (E7).
    case pin(String, attemptsLeft: Int)

    var mode: PairHelloData.Mode {
        switch self {
        case .qr: .qr
        case .pin: .pin
        }
    }
}

/// Everything the client stores once `pair/done` checks out (PAIR-01 API 5 logic 2).
public struct PairingResult: Sendable, Equatable {
    public let pairId: String
    public let createdAt: Int64
    public let phoneDeviceId: String
    public let phoneName: String
    public let phoneModel: String
    public let phoneOSVersion: String
    public let phoneSigningPublicKey: Data
    public let phoneDHPublicKey: Data
    /// `tls_sha256` of the offer, protected by its MAC; on the LAN also equal to the certificate seen.
    public let certificateSHA256: Data
    public let attestation: Data
    public let signatureSelf: Data
    public let signaturePeer: Data
    public let prk: Data

    public init(pairId: String, createdAt: Int64, phoneDeviceId: String, phoneName: String, phoneModel: String,
                phoneOSVersion: String, phoneSigningPublicKey: Data, phoneDHPublicKey: Data, certificateSHA256: Data,
                attestation: Data, signatureSelf: Data, signaturePeer: Data, prk: Data) {
        self.pairId = pairId
        self.createdAt = createdAt
        self.phoneDeviceId = phoneDeviceId
        self.phoneName = phoneName
        self.phoneModel = phoneModel
        self.phoneOSVersion = phoneOSVersion
        self.phoneSigningPublicKey = phoneSigningPublicKey
        self.phoneDHPublicKey = phoneDHPublicKey
        self.certificateSHA256 = certificateSHA256
        self.attestation = attestation
        self.signatureSelf = signatureSelf
        self.signaturePeer = signaturePeer
        self.prk = prk
    }
}

/// Why an exchange ended without a pair.
public enum PairingFailure: Error, Sendable, Equatable {
    /// E4: wrong MAC, signature, `device_id` or TLS binding — never says which (API 3 logic 3).
    case authFailed
    /// E7: the phone used another PIN; `attemptsLeft` is what this PIN has left (0 → make a new PIN).
    case pinInvalid(attemptsLeft: Int)
    /// The phone's pairing window is closed or serves another client (`PAIRING_CLOSED`).
    case pairingClosed
    /// The phone refused with another code (`QR_INVALID`, `INTERNAL`).
    case rejected(ErrorCode)
    /// The connection ended or timed out before the exchange finished.
    case disconnected
}
