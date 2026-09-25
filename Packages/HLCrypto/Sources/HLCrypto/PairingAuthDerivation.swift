import Foundation
import HLProtocol

/// One side of the pairing exchange as `T_offer` binds it (PAIR-01 API 2–3).
public struct PairingParty: Sendable, Equatable {
    public let deviceId: String
    public let nonce: Data
    public let signingPublicKey: Data
    public let dhPublicKey: Data
    public let name: String

    public init(deviceId: String, nonce: Data, signingPublicKey: Data, dhPublicKey: Data, name: String) {
        self.deviceId = deviceId
        self.nonce = nonce
        self.signingPublicKey = signingPublicKey
        self.dhPublicKey = dhPublicKey
        self.name = name
    }
}

/// The fields of the pairing attestation (0.6.2), in its byte order.
public struct PairingAttestationFields: Sendable, Equatable {
    public let pairId: String
    public let androidDeviceId: String
    public let clientDeviceId: String
    public let androidSigningKey: Data
    public let clientSigningKey: Data
    public let createdAt: Int64

    public init(pairId: String, androidDeviceId: String, clientDeviceId: String, androidSigningKey: Data,
                clientSigningKey: Data, createdAt: Int64) {
        self.pairId = pairId
        self.androidDeviceId = androidDeviceId
        self.clientDeviceId = clientDeviceId
        self.androidSigningKey = androidSigningKey
        self.clientSigningKey = clientSigningKey
        self.createdAt = createdAt
    }
}

/// Which side a `prk_check` comes from: the Mac/iPhone (`pair/confirm`) or Android (`pair/done`).
public enum PairingRole: Sendable {
    case client, server
}

/// Byte strings and keys of the pairing exchange (PAIR-01 API 3–5, 0.6.2). No JSON is signed or MACed; every field is
/// raw bytes: uuids as 16 bytes, timestamps as int64 BE, `str(x)` = uint16 BE length ‖ UTF-8. The labels are ASCII
/// without spaces ("HL1|confirm|"): the spaces around `|` in the spec tables come from Markdown escaping, as for the
/// envelope AAD of 0.5.1. Same bytes as the Android implementation; the tests share its expected values.
public enum PairingAuthDerivation {
    public static let authInfo = "handlive/v1/pair-auth"
    static let offerLabel = Data("HL1|offer|".utf8)
    static let confirmLabel = Data("HL1|confirm|".utf8)
    static let doneLabel = Data("HL1|done|".utf8)
    static let prkCheckClientLabel = Data("HL1|prk-check-c|".utf8)
    static let prkCheckServerLabel = Data("HL1|prk-check-s|".utf8)
    static let attestationLabel = Data("HLPAIR1".utf8)

    /// `K_pa` = HKDF-SHA256(ikm = `pairing_secret` or `K_pin`, salt = `nonce_c` ‖ `nonce_s`, info "handlive/v1/pair-auth").
    public static func authKey(secret: Data, clientNonce: Data, serverNonce: Data) -> Data {
        HKDFSHA256.derive(ikm: secret, salt: clientNonce + serverNonce, info: authInfo)
    }

    /// `K_pin` = Argon2id(PIN as UTF-8, salt = `nonce_c` ‖ `nonce_s`, t = 3, m = 64 MiB, p = 4, L = 32).
    /// Takes about 0.1 s in a release build: call it off the main actor.
    public static func pinKey(pin: String, clientNonce: Data, serverNonce: Data,
                              parameters: Argon2id.Parameters = .pairingPIN) -> Data {
        Argon2id.hash(password: Data(pin.utf8), salt: clientNonce + serverNonce, parameters: parameters)
    }

    /// `T_offer` = "HL1|offer|" ‖ `device_id` C ‖ `nonce_c` ‖ `ik_sig_pub` C ‖ `ik_dh_pub` C ‖ str(`name` C) ‖
    /// `device_id` S ‖ `nonce_s` ‖ `ik_sig_pub` S ‖ `ik_dh_pub` S ‖ `tls_sha256` ‖ str(`name` S).
    public static func offerTranscript(client: PairingParty, server: PairingParty, tlsSHA256: Data) throws -> Data {
        try Bytes.require(tlsSHA256, count: 32)
        var transcript = offerLabel
        try append(client, to: &transcript)
        transcript += try HLUUID.bytes(from: server.deviceId)
        transcript += try fixed(server.nonce) + fixed(server.signingPublicKey) + fixed(server.dhPublicKey)
        transcript += tlsSHA256
        transcript += try str(server.name)
        return transcript
    }

    /// `mac` of `pair/offer`: HMAC-SHA256(`K_pa`, `T_offer`).
    public static func offerMac(authKey: Data, transcript: Data) -> Data {
        HMACSHA256.mac(key: authKey, message: transcript)
    }

    /// `mac` of `pair/confirm`: HMAC(`K_pa`, "HL1|confirm|" ‖ `T_offer` ‖ `pair_id` ‖ `created_at` ‖ `sig`).
    public static func confirmMac(authKey: Data, transcript: Data, pairId: String, createdAt: Int64,
                                  clientSignature: Data) throws -> Data {
        let message = try confirmLabel + transcript + HLUUID.bytes(from: pairId) + int64(createdAt) + clientSignature
        return HMACSHA256.mac(key: authKey, message: message)
    }

    /// `mac` of `pair/done`: HMAC(`K_pa`, "HL1|done|" ‖ `pair_id` ‖ `sig`).
    public static func doneMac(authKey: Data, pairId: String, serverSignature: Data) throws -> Data {
        HMACSHA256.mac(key: authKey, message: try doneLabel + HLUUID.bytes(from: pairId) + serverSignature)
    }

    /// `prk_check` of the client (`pair/confirm`) or of Android (`pair/done`): HMAC(`PRK`, label ‖ `pair_id`).
    public static func prkCheck(prk: Data, pairId: String, role: PairingRole) throws -> Data {
        let label = role == .client ? prkCheckClientLabel : prkCheckServerLabel
        return HMACSHA256.mac(key: prk, message: try label + HLUUID.bytes(from: pairId))
    }

    /// Pairing attestation (0.6.2): "HLPAIR1" ‖ `pair_id` ‖ `device_id` Android ‖ `device_id` client ‖ `ik_sig_pub`
    /// Android ‖ `ik_sig_pub` client ‖ `created_at`. Both sides sign it; the relay checks both signatures.
    public static func attestation(_ fields: PairingAttestationFields) throws -> Data {
        var bytes = attestationLabel
        bytes += try HLUUID.bytes(from: fields.pairId)
        bytes += try HLUUID.bytes(from: fields.androidDeviceId)
        bytes += try HLUUID.bytes(from: fields.clientDeviceId)
        bytes += try fixed(fields.androidSigningKey) + fixed(fields.clientSigningKey)
        bytes += int64(fields.createdAt)
        return bytes
    }

    /// TXT `pr` of the phone's pairing window (PAIR-01 step 6): the first 8 hex digits of SHA-256(`pk`).
    public static func pairingRequestHint(clientDHPublicKey: Data) -> String {
        HMACSHA256.sha256(clientDHPublicKey).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ party: PairingParty, to transcript: inout Data) throws {
        transcript += try HLUUID.bytes(from: party.deviceId)
        transcript += try fixed(party.nonce) + fixed(party.signingPublicKey) + fixed(party.dhPublicKey)
        transcript += try str(party.name)
    }

    /// Nonces and keys are 32 bytes each.
    private static func fixed(_ value: Data) throws -> Data {
        try Bytes.require(value, count: 32)
        return value
    }

    /// `str(x)` = uint16 BE length ‖ UTF-8.
    static func str(_ text: String) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= Int(UInt16.max) else { throw CryptoError.fieldTooLong }
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]) + bytes
    }

    static func int64(_ value: Int64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
