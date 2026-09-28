import Foundation
import HLCrypto
import HLProtocol

extension RelayAPIClient {
    // MARK: - Endpoints (0.7.4)

    /// PAIR-01 API 8 logic 6: a 404 `DEVICE_NOT_FOUND` (this device or the phone unknown to the relay) registers this
    /// device again once and retries; a second 404 is thrown so the caller waits 24 h.
    public func registerPair(_ registration: RelayPairRegistration) async throws {
        do {
            _ = try await call("POST", "pairs", body: registration, authorized: true, as: RelayPairRegistered.self)
        } catch RelayAPIError.http(404, _, _) {
            try await registerDevice()
            _ = try await call("POST", "pairs", body: registration, authorized: true, as: RelayPairRegistered.self)
        }
    }

    public func pairs() async throws -> RelayPairList {
        try await perform("GET", "pairs", body: nil, authorized: true, as: RelayPairList.self)
    }

    /// PAIR-03 API 3 and step 8: the body carries this device's `HLREVOKE1` statement, signed now, so a retry after E3
    /// signs a new one within the relay's ±10 minutes; a pair the relay does not know counts as revoked (E4).
    public func revokePair(pairId: String, reason: RelayPairRevokeRequest.Reason) async throws {
        guard HLUUID.isCanonical(pairId) else { throw RelayAPIError.malformedResponse }
        let statement = try revocation(of: pairId)
        let body = RelayPairRevokeRequest(revokedAt: statement.revokedAt, sig: statement.sig, reason: reason)
        do {
            _ = try await call("POST", "pairs/\(pairId)/revoke", body: body, authorized: true, as: NoContent.self)
        } catch RelayAPIError.http(404, _, _) {
            return
        }
    }

    public func updatePushToken(_ request: RelayPushTokenRequest) async throws {
        _ = try await call("PUT", "devices/me/push-token", body: request, authorized: true, as: NoContent.self)
    }

    public func push(_ request: RelayPushRequest) async throws {
        _ = try await call("POST", "push", body: request, authorized: true, as: NoContent.self)
    }

    /// SET-02 API 2 and E6: a device the relay no longer knows (404 at the challenge or at the call) is already deleted.
    /// With `revokePairs` the body carries one `HLREVOKE1` statement for each pair the relay still lists as unrevoked.
    public func deleteDevice(revokePairs: Bool) async throws {
        defer { dropToken() }
        do {
            _ = try await accessToken(registerIfUnknown: false)
            var body: Data?
            if revokePairs {
                let open = try await perform("GET", "pairs", query: [URLQueryItem(name: "include_revoked", value: "false")],
                                             body: nil, authorized: true, registerIfUnknown: false, as: RelayPairList.self)
                let revocations = try open.pairs.filter { $0.revokedAt == nil }.map { try revocation(of: $0.pairId) }
                body = try HLJSON.encode(RelayDeviceDeleteRequest(revocations: revocations))
            }
            _ = try await perform("DELETE", "devices/me", query: [URLQueryItem(name: "revoke_pairs", value: "\(revokePairs)")],
                                  body: body, authorized: true, registerIfUnknown: false, as: NoContent.self)
        } catch RelayAPIError.http(404, _, _) {
            return
        }
    }

    /// This device's `HLREVOKE1` statement for `pairId`, signed with `ik_sig` at the current time (0.6.2).
    func revocation(of pairId: String) throws -> RelayRevocation {
        let revokedAt = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        let sig = try RevokeStatement.sign(pairId: pairId, by: identity.deviceId, revokedAt: revokedAt,
                                           seed: identity.signingSeed)
        return RelayRevocation(pairId: pairId, revokedAt: revokedAt, sig: Base64Coding.encodeB64u(sig))
    }

    // MARK: - Plumbing

    /// Body of a 2xx answer that carries nothing the client needs (204, or 202 `{"accepted":true}`).
    struct NoContent: Decodable {}

    func call<Response: Decodable>(_ method: String, _ path: String, body: some Encodable, authorized: Bool,
                                   as type: Response.Type) async throws -> Response {
        try await perform(method, path, body: try HLJSON.encode(body), authorized: authorized, as: type)
    }

    /// One call; with `authorized` it carries the JWT and is retried once after `401 TOKEN_EXPIRED` (0.6.4 step 3).
    func perform<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data?,
                                      authorized: Bool, registerIfUnknown: Bool = true,
                                      as type: Response.Type) async throws -> Response {
        guard let url = configuration.restURL(path, query: query) else { throw RelayAPIError.malformedResponse }
        var retried = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if authorized {
                let jwt = try await accessToken(registerIfUnknown: registerIfUnknown)
                request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            }
            let response = try await exchange(request)
            if (200..<300).contains(response.status) { return try Self.decode(response.body, as: type) }
            let error = Self.error(from: response)
            if authorized, !retried, error.code == .tokenExpired {
                dropToken()
                retried = true
                continue
            }
            throw error
        }
    }

    private func exchange(_ request: URLRequest) async throws -> RelayHTTPResponse {
        do {
            return try await transport.send(request)
        } catch RelayTransportError.pinMismatch {
            throw RelayAPIError.pinMismatch
        } catch RelayTransportError.unreachable(let detail) {
            throw RelayAPIError.unreachable(detail)
        } catch {
            throw RelayAPIError.unreachable("transport")
        }
    }

    static func decode<Response: Decodable>(_ body: Data, as type: Response.Type) throws -> Response {
        if type == NoContent.self, let empty = NoContent() as? Response { return empty }
        guard let value = try? HLJSON.decode(type, from: body) else { throw RelayAPIError.malformedResponse }
        return value
    }

    static func error(from response: RelayHTTPResponse) -> RelayAPIError {
        let code = (try? HLJSON.decode(RelayErrorBody.self, from: response.body))?.error.code ?? .unrecognized
        return .http(status: response.status, code: code, retryAfter: response.retryAfter)
    }
}
