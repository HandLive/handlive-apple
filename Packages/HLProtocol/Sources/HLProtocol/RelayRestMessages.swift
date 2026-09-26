// Bodies of the relay REST API (0.7.4, 0.8.2): CONN-03 API 1–3, CONN-04 API 1–2, PAIR-01 API 8, PAIR-02 API 1,
// PAIR-03 API 3. Byte values travel as b64u (0.3).

/// `POST /v1/devices` (CONN-03 API 1); `sig` = Ed25519(`ik_sig`, `"HLREG1"` ‖ …) — `RelayAuthMessage.register`.
public struct RelayDeviceRegistration: Codable, Equatable, Sendable {
    public let deviceId: String
    public let platform: String
    public let appVersion: String
    public let ikSigPub: String
    public let ts: Int64
    public let sig: String

    public init(deviceId: String, platform: String, appVersion: String, ikSigPub: String, ts: Int64, sig: String) {
        self.deviceId = deviceId
        self.platform = platform
        self.appVersion = appVersion
        self.ikSigPub = ikSigPub
        self.ts = ts
        self.sig = sig
    }

    enum CodingKeys: String, CodingKey {
        case platform, ts, sig
        case deviceId = "device_id"
        case appVersion = "app_version"
        case ikSigPub = "ik_sig_pub"
    }
}

/// Response of `POST /v1/devices` (201 new, 200 already registered).
public struct RelayDeviceRegistered: Codable, Equatable, Sendable {
    public let deviceId: String
    public let createdAt: Int64

    public init(deviceId: String, createdAt: Int64) {
        self.deviceId = deviceId
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case createdAt = "created_at"
    }
}

/// `POST /v1/auth/challenge` (CONN-03 API 2).
public struct RelayChallengeRequest: Codable, Equatable, Sendable {
    public let deviceId: String

    public init(deviceId: String) {
        self.deviceId = deviceId
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
    }
}

public struct RelayChallenge: Codable, Equatable, Sendable {
    /// b64u of 32 bytes; valid 60 s.
    public let challenge: String
    public let expiresAt: Int64

    public init(challenge: String, expiresAt: Int64) {
        self.challenge = challenge
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case challenge
        case expiresAt = "expires_at"
    }
}

/// `POST /v1/auth/token` (CONN-03 API 3); `sig` = Ed25519(`ik_sig`, `"HLAUTH1"` ‖ challenge ‖ `device_id`).
public struct RelayTokenRequest: Codable, Equatable, Sendable {
    public let deviceId: String
    public let challenge: String
    public let sig: String

    public init(deviceId: String, challenge: String, sig: String) {
        self.deviceId = deviceId
        self.challenge = challenge
        self.sig = sig
    }

    enum CodingKeys: String, CodingKey {
        case challenge, sig
        case deviceId = "device_id"
    }
}

/// HS256 JWT, valid `expires_in` seconds (900).
public struct RelayToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let expiresIn: Int32

    public init(accessToken: String, expiresIn: Int32) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

/// `PUT /v1/devices/me/push-token` (CONN-04 API 1): `topic` (bundle id) with APNs.
public struct RelayPushTokenRequest: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case fcm, apns
        case apnsSandbox = "apns_sandbox"
    }

    public let provider: Provider
    public let token: String
    public let topic: String?

    public init(provider: Provider, token: String, topic: String?) {
        self.provider = provider
        self.token = token
        self.topic = topic
    }
}

/// `POST /v1/push` (CONN-04 API 2): `wake` only to Android, `alert` only to iOS/iPadOS.
public struct RelayPushRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case wake, alert
    }

    public enum Reason: String, Codable, Sendable {
        case userOpen = "user_open"
        case smsSend = "sms_send"
        case callAction = "call_action"
        case smsNew = "sms_new"
        case callIncoming = "call_incoming"
        case callMissed = "call_missed"
    }

    public let pairId: String
    public let to: String
    public let kind: Kind
    public let reason: Reason
    public let envB64: String?
    public let collapseKey: String?
    public let ttlS: Int32?

    public init(pairId: String, to: String, kind: Kind, reason: Reason, envB64: String? = nil,
                collapseKey: String? = nil, ttlS: Int32? = nil) {
        self.pairId = pairId
        self.to = to
        self.kind = kind
        self.reason = reason
        self.envB64 = envB64
        self.collapseKey = collapseKey
        self.ttlS = ttlS
    }

    enum CodingKeys: String, CodingKey {
        case to, kind, reason
        case pairId = "pair_id"
        case envB64 = "env_b64"
        case collapseKey = "collapse_key"
        case ttlS = "ttl_s"
    }
}

/// Error body of the relay REST API: `{"error":{"code","message"}}` (0.4.3, 0.8.2).
public struct RelayErrorBody: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public let code: RelayRestErrorCode
        public let message: String

        public init(code: RelayRestErrorCode, message: String) {
            self.code = code
            self.message = message
        }
    }

    public let error: Detail

    public init(code: RelayRestErrorCode, message: String) {
        error = Detail(code: code, message: message)
    }
}

/// Relay HTTP error codes (0.8.2); an unknown code reads as `.unrecognized` and is handled like `INTERNAL`.
public enum RelayRestErrorCode: String, Codable, Sendable, LenientStringEnum {
    case badRequest = "BAD_REQUEST"
    case challengeExpired = "CHALLENGE_EXPIRED"
    case signatureInvalid = "SIGNATURE_INVALID"
    case tokenExpired = "TOKEN_EXPIRED"
    case notPaired = "NOT_PAIRED"
    case deviceNotFound = "DEVICE_NOT_FOUND"
    case pairExists = "PAIR_EXISTS"
    case pushTokenMissing = "PUSH_TOKEN_MISSING"
    case deviceRevoked = "DEVICE_REVOKED"
    case payloadTooLarge = "PAYLOAD_TOO_LARGE"
    case rateLimited = "RATE_LIMITED"
    case `internal` = "INTERNAL"
    case pushProviderError = "PUSH_PROVIDER_ERROR"
    case unrecognized = ""
}
