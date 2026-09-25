// `data` of the `pair` ops (PAIR-01 API 2–6, PAIR-03 API 1).

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
