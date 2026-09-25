// `data` of the `pair` ops (PAIR-01 API 2–6, PAIR-03 API 1). Keys, nonces and MACs are b64u 32 bytes, signatures
// b64u 64 bytes. The five PAIR-01 ops travel with an unencrypted payload (0.5.1 exception 1).

/// `op` names of `type = pair` (0.7.1).
public enum PairOp: String, Sendable {
    case hello, offer, confirm, done, error, revoke
}

/// `pair/hello` C→S (PAIR-01 API 2).
public struct PairHelloData: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case qr, pin
    }

    public let mode: Mode
    public let deviceId: String
    public let nonce: String
    public let name: String
    public let platform: CapabilityData.Platform
    public let model: String?
    public let ikSigPub: String
    public let ikDhPub: String

    public init(mode: Mode, deviceId: String, nonce: String, name: String, platform: CapabilityData.Platform,
                model: String?, ikSigPub: String, ikDhPub: String) {
        self.mode = mode
        self.deviceId = deviceId
        self.nonce = nonce
        self.name = name
        self.platform = platform
        self.model = model
        self.ikSigPub = ikSigPub
        self.ikDhPub = ikDhPub
    }

    enum CodingKeys: String, CodingKey {
        case mode, nonce, name, platform, model
        case deviceId = "device_id"
        case ikSigPub = "ik_sig_pub"
        case ikDhPub = "ik_dh_pub"
    }
}

/// `pair/offer` S→C (PAIR-01 API 3): integrity by `mac` = HMAC(`K_pa`, `T_offer`).
public struct PairOfferData: Codable, Equatable, Sendable {
    public let deviceId: String
    public let nonce: String
    public let name: String
    public let model: String
    public let osVersion: String
    public let ikSigPub: String
    public let ikDhPub: String
    public let tlsSha256: String
    public let mac: String

    public init(deviceId: String, nonce: String, name: String, model: String, osVersion: String, ikSigPub: String,
                ikDhPub: String, tlsSha256: String, mac: String) {
        self.deviceId = deviceId
        self.nonce = nonce
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.ikSigPub = ikSigPub
        self.ikDhPub = ikDhPub
        self.tlsSha256 = tlsSha256
        self.mac = mac
    }

    enum CodingKeys: String, CodingKey {
        case nonce, name, model, mac
        case deviceId = "device_id"
        case osVersion = "os_version"
        case ikSigPub = "ik_sig_pub"
        case ikDhPub = "ik_dh_pub"
        case tlsSha256 = "tls_sha256"
    }
}

/// `pair/confirm` C→S (PAIR-01 API 4).
public struct PairConfirmData: Codable, Equatable, Sendable {
    public let pairId: String
    public let createdAt: Int64
    public let sig: String
    public let prkCheck: String
    public let mac: String

    public init(pairId: String, createdAt: Int64, sig: String, prkCheck: String, mac: String) {
        self.pairId = pairId
        self.createdAt = createdAt
        self.sig = sig
        self.prkCheck = prkCheck
        self.mac = mac
    }

    enum CodingKeys: String, CodingKey {
        case sig, mac
        case pairId = "pair_id"
        case createdAt = "created_at"
        case prkCheck = "prk_check"
    }
}

/// `pair/done` S→C (PAIR-01 API 5).
public struct PairDoneData: Codable, Equatable, Sendable {
    public let sig: String
    public let prkCheck: String
    public let mac: String

    public init(sig: String, prkCheck: String, mac: String) {
        self.sig = sig
        self.prkCheck = prkCheck
        self.mac = mac
    }

    enum CodingKeys: String, CodingKey {
        case sig, mac
        case prkCheck = "prk_check"
    }
}

/// `pair/error` both ways (PAIR-01 API 6): `message` is an English diagnostic without sensitive data;
/// `attempts_left` comes only with `PIN_INVALID`.
public struct PairErrorData: Codable, Equatable, Sendable {
    public static let allowedCodes: Set<ErrorCode> = [.qrInvalid, .pairingClosed, .pinInvalid, .authFailed, .internal]

    public let code: ErrorCode
    public let message: String
    public let attemptsLeft: Int32?

    public init(code: ErrorCode, message: String, attemptsLeft: Int32? = nil) {
        self.code = code
        self.message = message
        self.attemptsLeft = code == .pinInvalid ? attemptsLeft : nil
    }

    enum CodingKeys: String, CodingKey {
        case code, message
        case attemptsLeft = "attempts_left"
    }
}

/// `pair/revoke` (PAIR-03 API 1): either side may end the pair; the receiver acks before deleting keys.
public struct PairRevokeData: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable, LenientStringEnum {
        case user, reinstall, limit
        case unrecognized = ""
    }

    public let pairId: String
    public let reason: Reason

    public init(pairId: String, reason: Reason) {
        self.pairId = pairId
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case pairId = "pair_id"
        case reason
    }
}
