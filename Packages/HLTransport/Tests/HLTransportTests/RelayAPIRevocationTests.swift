import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// PAIR-03 step 8 and SET-02 API 2: revocations sent to the relay carry this device's signed statement.
extension RelayAPIClientTests {
    static let pairA = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    static let pairB = "7a1e2b3c-4d5e-4f60-9172-83a4b5c6d7e8"
    static let pairC = "0192f3d8-2b11-4c42-8e5a-6b7c8d9e0f12"

    /// `GET /v1/pairs` with pair A unrevoked and pair B revoked.
    static func listing(_ request: URLRequest) -> RelayHTTPResponse {
        guard request.httpMethod == "GET", request.url?.path == "/v1/pairs" else { return standard(request) }
        return ScriptedRelayHTTP.json(200, #"{"pairs":[{"pair_id":"\#(pairA)","#
            + #""peer_device_id":"8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f","peer_platform":"android","created_at":1,"#
            + #""revoked_at":null,"peer_online":true},{"pair_id":"\#(pairB)","#
            + #""peer_device_id":"8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f","peer_platform":"android","created_at":1,"#
            + #""revoked_at":1,"revoked_by":null,"revoke_sig":null,"peer_online":false}]}"#)
    }

    /// Pair ids of a DELETE body, each statement checked.
    static func signedPairs(_ request: URLRequest) throws -> Set<String> {
        let revocations = try #require(try jsonBody(request)["revocations"] as? [[String: Any]])
        var ids = Set<String>()
        for item in revocations {
            let pairId = try #require(item["pair_id"] as? String)
            _ = try verifyStatement(item, pairId: pairId)
            ids.insert(pairId)
        }
        #expect(ids.count == revocations.count) // one statement per pair
        return ids
    }

    static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Checks one `HLREVOKE1` statement of this device (0.6.2) and returns its `revoked_at`.
    static func verifyStatement(_ object: [String: Any], pairId: String) throws -> Int64 {
        let revokedAt = try #require(object["revoked_at"] as? NSNumber).int64Value
        let sig = try Base64Coding.decodeB64u(try #require(object["sig"] as? String))
        let identity = try identity()
        #expect(RevokeStatement.verify(sig, pairId: pairId, by: identity.deviceId, revokedAt: revokedAt,
                                       publicKey: identity.signingPublicKey))
        return revokedAt
    }

    @Test("SET-02: DELETE with revoke_pairs; a device the relay no longer knows is already deleted (E6)")
    func deleteDevice() async throws {
        let http = ScriptedRelayHTTP(Self.listing)
        let clock = TestClock()
        try await Self.client(http, clock: clock).deleteDevice(revokePairs: true, localPairIds: [Self.pairC, Self.pairA])
        let delete = try #require(http.requests.last)
        #expect(delete.url?.absoluteString == "https://relay.example.com/v1/devices/me?revoke_pairs=true")
        #expect(delete.httpMethod == "DELETE")
        // Every local pair and every pair the relay still lists as unrevoked (SET-02 API 2).
        #expect(try Self.signedPairs(delete) == [Self.pairA, Self.pairC])
        let first = try #require(try Self.jsonBody(delete)["revocations"] as? [[String: Any]]).first
        #expect(try Self.verifyStatement(try #require(first), pairId: first?["pair_id"] as? String ?? "")
                == Int64(clock.now.timeIntervalSince1970 * 1000))
        let silent = ScriptedRelayHTTP(Self.standard)
        try await Self.client(silent).deleteDevice(revokePairs: false, localPairIds: [Self.pairA])
        #expect(silent.requests.last?.httpBody == nil)
        #expect(!silent.paths.contains("GET /v1/pairs"))
        let gone = ScriptedRelayHTTP { request in
            request.url?.path == "/v1/auth/challenge" ? ScriptedRelayHTTP.error(404, "DEVICE_NOT_FOUND") : Self.standard(request)
        }
        try await Self.client(gone).deleteDevice(revokePairs: false, localPairIds: [])
        #expect(gone.paths == ["POST /v1/auth/challenge"])
    }

    @Test("SET-02 API 2: a 400 on DELETE lists and signs again and retries once; a second 400 is reported")
    func deleteRetriesAfterBadRequest() async throws {
        let deletes = Counter()
        let once = ScriptedRelayHTTP { request in
            if request.httpMethod == "DELETE" {
                return deletes.next() < 1 ? ScriptedRelayHTTP.error(400, "BAD_REQUEST") : ScriptedRelayHTTP.json(204, "")
            }
            return Self.listing(request)
        }
        try await Self.client(once).deleteDevice(revokePairs: true, localPairIds: [])
        #expect(once.paths.filter { !$0.contains("/auth/") }
            == ["GET /v1/pairs", "DELETE /v1/devices/me", "GET /v1/pairs", "DELETE /v1/devices/me"])
        let always = ScriptedRelayHTTP { request in
            request.httpMethod == "DELETE" ? ScriptedRelayHTTP.error(400, "BAD_REQUEST") : Self.listing(request)
        }
        await #expect(throws: RelayAPIError.http(status: 400, code: .badRequest, retryAfter: nil)) {
            try await Self.client(always).deleteDevice(revokePairs: true, localPairIds: [])
        }
        #expect(always.paths.filter { $0 == "DELETE /v1/devices/me" }.count == 2)
    }

    @Test("PAIR-03 step 8: the revoke body carries this device's HLREVOKE1 statement; a retry signs a new one")
    func revokeIsSigned() async throws {
        let http = ScriptedRelayHTTP(Self.standard)
        let clock = TestClock()
        let client = try Self.client(http, clock: clock)
        try await client.revokePair(pairId: Self.pairA, reason: .user)
        clock.advance(90)
        try await client.revokePair(pairId: Self.pairA, reason: .user)
        let bodies = try http.requests.filter { $0.url?.path == "/v1/pairs/\(Self.pairA)/revoke" }.map(Self.jsonBody)
        #expect(bodies.count == 2)
        let first = try Self.verifyStatement(bodies[0], pairId: Self.pairA)
        let second = try Self.verifyStatement(bodies[1], pairId: Self.pairA)
        #expect(second - first == 90_000)
        #expect(bodies[0]["sig"] as? String != bodies[1]["sig"] as? String)
    }
}
