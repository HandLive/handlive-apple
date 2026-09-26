// Relay REST bodies about pairs: PAIR-01 API 8, PAIR-02 API 1, PAIR-03 API 3 (0.7.4).

/// `POST /v1/pairs` (PAIR-01 API 8): the attestation of 0.6.2 with both signatures.
public struct RelayPairRegistration: Codable, Equatable, Sendable {
    public let pairId: String
    /// Android.
    public let deviceA: String
    /// Mac/iOS.
    public let deviceB: String
    public let createdAt: Int64
    public let attestation: String
    public let sigA: String
    public let sigB: String

    public init(pairId: String, deviceA: String, deviceB: String, createdAt: Int64, attestation: String, sigA: String,
                sigB: String) {
        self.pairId = pairId
        self.deviceA = deviceA
        self.deviceB = deviceB
        self.createdAt = createdAt
        self.attestation = attestation
        self.sigA = sigA
        self.sigB = sigB
    }

    enum CodingKeys: String, CodingKey {
        case attestation
        case pairId = "pair_id"
        case deviceA = "device_a"
        case deviceB = "device_b"
        case createdAt = "created_at"
        case sigA = "sig_a"
        case sigB = "sig_b"
    }
}

/// `GET /v1/pairs` (PAIR-02 API 1): a pair with a `revoked_at` was revoked; a local pair absent here is not.
public struct RelayPairList: Codable, Equatable, Sendable {
    public let pairs: [RelayPairEntry]
}

/// One pair of `GET /v1/pairs`: `revoked_at` set means revoked; `peer_online` comes from the relay's presence.
public struct RelayPairEntry: Codable, Equatable, Sendable {
    public let pairId: String
    public let peerDeviceId: String
    public let peerPlatform: CapabilityData.Platform
    public let createdAt: Int64
    public let revokedAt: Int64?
    public let peerOnline: Bool

    enum CodingKeys: String, CodingKey {
        case pairId = "pair_id"
        case peerDeviceId = "peer_device_id"
        case peerPlatform = "peer_platform"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
        case peerOnline = "peer_online"
    }
}

/// `POST /v1/pairs/{pair_id}/revoke` (PAIR-03 API 3).
public struct RelayPairRevokeRequest: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case user, reinstall
        case lostDevice = "lost_device"
    }

    public let reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }
}
