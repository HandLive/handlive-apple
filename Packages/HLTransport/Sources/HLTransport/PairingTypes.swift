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
public enum PairingCredential: Sendable {
    /// With a rendezvous joined on the relay, the QR code carries its `rv` and the phone may pair through it (P2).
    case qr(secret: Data, rendezvous: PairingRendezvous? = nil)
    /// `attemptsLeft` counts this attempt: 3 for a new PIN; a wrong PIN leaves one fewer (E7). `attempts`, when
    /// set (`PairingController`, via `BluetoothFallbackPairingSearch`), is the counter the LAN exchange and the
    /// Bluetooth search actually spend from in common (C3): `attemptsLeft` alone is a snapshot that can go stale
    /// once the other transport also spends from the same counter, so code that enforces the limit must prefer
    /// `attempts` over `attemptsLeft` whenever it is present (Trang's finding, #3932).
    case pin(String, attemptsLeft: Int, attempts: PinAttemptCounter? = nil)
    /// Flow C over Bluetooth (PAIR-01 C3): `K_bt_pin` from the channel's CPace `ISK`, in place of the Argon2id
    /// `K_pin`. `pair/hello` says `mode = "pin"`; a wrong PIN already failed the link handshake before this runs
    /// (`BtPinPairingSearch`), so a bad `mac` here is `AUTH_FAILED`, not `PIN_INVALID`. Never used on the LAN.
    case bluetoothPIN(key: Data)

    var mode: PairHelloData.Mode {
        switch self {
        case .qr: .qr
        case .pin, .bluetoothPIN: .pin
        }
    }

    /// `.pin`'s shared attempt counter, if any (`PairingController` reattaches it to the next round's credential).
    public var pinAttemptsCounter: PinAttemptCounter? {
        if case .pin(_, _, let attempts) = self { return attempts }
        return nil
    }
}

/// Compares `pin`'s `attemptsLeft` snapshot only: `attempts`, when attached, is a shared actor identified by
/// reference, not by value, and is never part of what makes two credentials "the same" (tests build `.pin` values
/// without it to assert against what `PairingController` produced with one attached).
extension PairingCredential: Equatable {
    public static func == (lhs: PairingCredential, rhs: PairingCredential) -> Bool {
        switch (lhs, rhs) {
        case (.qr(let lSecret, let lRendezvous), .qr(let rSecret, let rRendezvous)):
            return lSecret == rSecret && lRendezvous == rRendezvous
        case (.pin(let lPin, let lLeft, _), .pin(let rPin, let rLeft, _)):
            return lPin == rPin && lLeft == rLeft
        case (.bluetoothPIN(let lKey), .bluetoothPIN(let rKey)):
            return lKey == rKey
        default:
            return false
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
    /// LAN address of the `/v1/pair` connection, so CONN-01 can use `last_host` before TXT `h=` refreshes.
    public let lanHost: String?
    public let lanPort: UInt16?

    public init(pairId: String, createdAt: Int64, phoneDeviceId: String, phoneName: String, phoneModel: String,
                phoneOSVersion: String, phoneSigningPublicKey: Data, phoneDHPublicKey: Data, certificateSHA256: Data,
                attestation: Data, signatureSelf: Data, signaturePeer: Data, prk: Data,
                lanHost: String? = nil, lanPort: UInt16? = nil) {
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
        self.lanHost = lanHost
        self.lanPort = lanPort
    }

    /// Attaches the resolved LAN address from the pairing WebSocket (relay rendezvous leaves these nil).
    public func withLAN(host: String, port: UInt16) -> PairingResult {
        PairingResult(pairId: pairId, createdAt: createdAt, phoneDeviceId: phoneDeviceId, phoneName: phoneName,
                      phoneModel: phoneModel, phoneOSVersion: phoneOSVersion,
                      phoneSigningPublicKey: phoneSigningPublicKey, phoneDHPublicKey: phoneDHPublicKey,
                      certificateSHA256: certificateSHA256, attestation: attestation, signatureSelf: signatureSelf,
                      signaturePeer: signaturePeer, prk: prk, lanHost: host, lanPort: port)
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
