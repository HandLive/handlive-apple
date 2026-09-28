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

/// Response of `POST /v1/pairs` (201 created, 200 already there with identical data).
public struct RelayPairRegistered: Codable, Equatable, Sendable {
    public let pairId: String
    public let createdAt: Int64

    public init(pairId: String, createdAt: Int64) {
        self.pairId = pairId
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case pairId = "pair_id"
        case createdAt = "created_at"
    }
}

/// `GET /v1/pairs` (PAIR-02 API 1): a pair with a `revoked_at` was revoked; a local pair absent here is not.
public struct RelayPairList: Codable, Equatable, Sendable {
    public let pairs: [RelayPairEntry]

    public init(pairs: [RelayPairEntry]) {
        self.pairs = pairs
    }
}

/// One pair of `GET /v1/pairs`: `revoked_at` set means revoked; `revoked_by` and `revoke_sig` carry the revoking device's
/// `HLREVOKE1` statement (`nil` on rows revoked before signed revocation); `peer_online` comes from the relay's presence.
public struct RelayPairEntry: Codable, Equatable, Sendable {
    public let pairId: String
    public let peerDeviceId: String
    public let peerPlatform: CapabilityData.Platform
    public let createdAt: Int64
    public let revokedAt: Int64?
    public let revokedBy: String?
    public let revokeSig: String?
    public let peerOnline: Bool

    public init(pairId: String, peerDeviceId: String, peerPlatform: CapabilityData.Platform, createdAt: Int64,
                revokedAt: Int64?, revokedBy: String? = nil, revokeSig: String? = nil, peerOnline: Bool) {
        self.pairId = pairId
        self.peerDeviceId = peerDeviceId
        self.peerPlatform = peerPlatform
        self.createdAt = createdAt
        self.revokedAt = revokedAt
        self.revokedBy = revokedBy
        self.revokeSig = revokeSig
        self.peerOnline = peerOnline
    }

    /// The row's revocation as the relay's `pair_revoked` would carry it (an empty `by` when the row names no one);
    /// `nil` while the pair is not revoked.
    public var revocation: RelayPairRevocation? {
        guard revokedAt != nil else { return nil }
        return RelayPairRevocation(pairId: pairId, by: revokedBy ?? "", revokedAt: revokedAt, sig: revokeSig)
    }

    enum CodingKeys: String, CodingKey {
        case pairId = "pair_id"
        case peerDeviceId = "peer_device_id"
        case peerPlatform = "peer_platform"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
        case revokedBy = "revoked_by"
        case revokeSig = "revoke_sig"
        case peerOnline = "peer_online"
    }
}

/// `POST /v1/pairs/{pair_id}/revoke` (PAIR-03 API 3): the caller's `HLREVOKE1` statement (0.6.2) and an informational
/// reason, which is not signed and not stored.
public struct RelayPairRevokeRequest: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case user, reinstall
        case lostDevice = "lost_device"
    }

    public let revokedAt: Int64
    /// b64u of the 64-byte signature.
    public let sig: String
    public let reason: Reason?

    public init(revokedAt: Int64, sig: String, reason: Reason?) {
        self.revokedAt = revokedAt
        self.sig = sig
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case revokedAt = "revoked_at"
        case sig, reason
    }
}

/// One item of `revocations[]` in `DELETE /v1/devices/me?revoke_pairs=true` (SET-02 API 2): a statement per pair.
public struct RelayRevocation: Codable, Equatable, Sendable {
    public let pairId: String
    public let revokedAt: Int64
    public let sig: String

    public init(pairId: String, revokedAt: Int64, sig: String) {
        self.pairId = pairId
        self.revokedAt = revokedAt
        self.sig = sig
    }

    enum CodingKeys: String, CodingKey {
        case pairId = "pair_id"
        case revokedAt = "revoked_at"
        case sig
    }
}

/// Body of `DELETE /v1/devices/me?revoke_pairs=true` (SET-02 API 2).
public struct RelayDeviceDeleteRequest: Codable, Equatable, Sendable {
    public let revocations: [RelayRevocation]

    public init(revocations: [RelayRevocation]) {
        self.revocations = revocations
    }
}
