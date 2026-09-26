import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// Answers relay REST requests from a script and records them.
final class ScriptedRelayHTTP: RelayHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> RelayHTTPResponse
    private let lock = NSLock()
    private var handler: Handler
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
        try record(request)(request)
    }

    private func record(_ request: URLRequest) -> Handler {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return handler
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
    }

    static func json(_ status: Int, _ body: String, retryAfter: TimeInterval? = nil) -> RelayHTTPResponse {
        RelayHTTPResponse(status: status, body: Data(body.utf8), retryAfter: retryAfter)
    }

    static func error(_ status: Int, _ code: String) -> RelayHTTPResponse {
        json(status, #"{"error":{"code":"\#(code)","message":"test"}}"#)
    }
}

/// Mutable clock for token lifetimes.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_727_151_100)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

@Suite("Relay REST client (CONN-03 API 1–3, 0.6.4, SET-02 API 2)")
struct RelayAPIClientTests {
    static let seed = (try? Hex.decode("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")) ?? Data()

    static func identity() throws -> RelayIdentity {
        let publicKey = try Ed25519.publicKey(seed: seed)
        return RelayIdentity(deviceId: try DeviceIdentity.deviceId(signingPublicKey: publicKey), signingSeed: seed,
                             signingPublicKey: publicKey, platform: .macos, appVersion: "1.0.0 (100)")
    }

    static let challenge = Base64Coding.encodeB64u(Data(repeating: 5, count: 32))

    /// A relay that knows the device and issues 15-minute tokens.
    static func standard(_ request: URLRequest) -> RelayHTTPResponse {
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/v1/auth/challenge"): return ScriptedRelayHTTP.json(200, #"{"challenge":"\#(challenge)","expires_at":1}"#)
        case ("POST", "/v1/auth/token"): return ScriptedRelayHTTP.json(200, #"{"access_token":"jwt-1","expires_in":900}"#)
        case ("POST", "/v1/devices"): return ScriptedRelayHTTP.json(201, #"{"device_id":"x","created_at":1}"#)
        case ("GET", "/v1/pairs"): return ScriptedRelayHTTP.json(200, #"{"pairs":[]}"#)
        default: return ScriptedRelayHTTP.json(204, "")
        }
    }

    static func client(_ http: ScriptedRelayHTTP, clock: TestClock = TestClock()) throws -> RelayAPIClient {
        RelayAPIClient(configuration: RelayConfiguration(host: "relay.example.com"), identity: try identity(),
                       transport: http, now: { clock.now })
    }

    @Test("Registration signs HLREG1 over device_id, ik_sig_pub, platform and ts")
    func registration() async throws {
        let http = ScriptedRelayHTTP(Self.standard)
        try await Self.client(http).registerDevice()
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://relay.example.com/v1/devices")
        let body = try HLJSON.decode(RelayDeviceRegistration.self, from: try #require(request.httpBody))
        let identity = try Self.identity()
        #expect(body.deviceId == identity.deviceId && body.platform == "macos" && body.appVersion == "1.0.0 (100)")
        #expect(body.ts == 1_727_151_100_000)
        let message = try RelayAuthMessage.register(deviceId: body.deviceId, signingPublicKey: identity.signingPublicKey,
                                                    platform: "macos", ts: body.ts)
        #expect(Ed25519.verify(try Base64Coding.decodeB64u(body.sig), message: message,
                               publicKey: try Base64Coding.decodeB64u(body.ikSigPub)))
    }

    @Test("Token: HLAUTH1 signature, Bearer on calls, reused while more than 60 s are left")
    func token() async throws {
        let clock = TestClock()
        let http = ScriptedRelayHTTP(Self.standard)
        let client = try Self.client(http, clock: clock)
        _ = try await client.pairs()
        _ = try await client.pairs()
        #expect(http.paths.filter { $0 == "POST /v1/auth/token" }.count == 1)
        let tokenRequest = try HLJSON.decode(RelayTokenRequest.self,
                                             from: try #require(http.requests[1].httpBody))
        let message = try RelayAuthMessage.token(challenge: Data(repeating: 5, count: 32), deviceId: tokenRequest.deviceId)
        #expect(Ed25519.verify(try Base64Coding.decodeB64u(tokenRequest.sig), message: message,
                               publicKey: try Self.identity().signingPublicKey))
        #expect(http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-1")
        clock.advance(841) // 59 s left: fetch a new one
        _ = try await client.pairs()
        #expect(http.paths.filter { $0 == "POST /v1/auth/token" }.count == 2)
    }

    @Test("401 TOKEN_EXPIRED: new token and one retry; a second refusal is reported")
    func tokenExpired() async throws {
        let refusals = Counter()
        let http = ScriptedRelayHTTP { request in
            if request.url?.path == "/v1/pairs", refusals.next() < 1 { return ScriptedRelayHTTP.error(401, "TOKEN_EXPIRED") }
            return Self.standard(request)
        }
        _ = try await Self.client(http).pairs()
        #expect(http.paths.filter { $0 == "GET /v1/pairs" }.count == 2)
        let always = ScriptedRelayHTTP { request in
            request.url?.path == "/v1/pairs" ? ScriptedRelayHTTP.error(401, "TOKEN_EXPIRED") : Self.standard(request)
        }
        await #expect(throws: RelayAPIError.http(status: 401, code: .tokenExpired, retryAfter: nil)) {
            _ = try await Self.client(always).pairs()
        }
    }

    @Test("E2: a relay that forgot the device gets a new registration, then the token")
    func reRegister() async throws {
        let challenges = Counter()
        let http = ScriptedRelayHTTP { request in
            if request.url?.path == "/v1/auth/challenge", challenges.next() < 1 {
                return ScriptedRelayHTTP.error(404, "DEVICE_NOT_FOUND")
            }
            return Self.standard(request)
        }
        #expect(try await Self.client(http).accessToken() == "jwt-1")
        #expect(http.paths == ["POST /v1/auth/challenge", "POST /v1/devices", "POST /v1/auth/challenge", "POST /v1/auth/token"])
    }

    @Test("SET-02: DELETE with revoke_pairs; a device the relay no longer knows is already deleted (E6)")
    func deleteDevice() async throws {
        let http = ScriptedRelayHTTP(Self.standard)
        try await Self.client(http).deleteDevice(revokePairs: true)
        #expect(http.requests.last?.url?.absoluteString == "https://relay.example.com/v1/devices/me?revoke_pairs=true")
        #expect(http.requests.last?.httpMethod == "DELETE")
        let gone = ScriptedRelayHTTP { request in
            request.url?.path == "/v1/auth/challenge" ? ScriptedRelayHTTP.error(404, "DEVICE_NOT_FOUND") : Self.standard(request)
        }
        try await Self.client(gone).deleteDevice(revokePairs: false)
        #expect(gone.paths == ["POST /v1/auth/challenge"])
    }

    @Test("Errors: 429 with Retry-After, 410 DEVICE_REVOKED, pin mismatch, unreachable, unknown code")
    func errors() async throws {
        let limited = ScriptedRelayHTTP { _ in ScriptedRelayHTTP.json(429, #"{"error":{"code":"RATE_LIMITED","message":""}}"#,
                                                                     retryAfter: 30) }
        await #expect(throws: RelayAPIError.http(status: 429, code: .rateLimited, retryAfter: 30)) {
            try await Self.client(limited).registerDevice()
        }
        let revoked = ScriptedRelayHTTP { _ in ScriptedRelayHTTP.error(410, "DEVICE_REVOKED") }
        do {
            try await Self.client(revoked).registerDevice()
            Issue.record("expected 410")
        } catch let error as RelayAPIError {
            #expect(error.isDeviceRevoked)
        }
        let pinned = ScriptedRelayHTTP { _ in throw RelayTransportError.pinMismatch }
        await #expect(throws: RelayAPIError.pinMismatch) { try await Self.client(pinned).registerDevice() }
        let down = ScriptedRelayHTTP { _ in throw RelayTransportError.unreachable("down") }
        await #expect(throws: RelayAPIError.unreachable("down")) { try await Self.client(down).registerDevice() }
        let odd = ScriptedRelayHTTP { _ in ScriptedRelayHTTP.json(500, "oops") }
        await #expect(throws: RelayAPIError.http(status: 500, code: .unrecognized, retryAfter: nil)) {
            try await Self.client(odd).registerDevice()
        }
    }

    @Test("PAIR-01 API 8 logic 6: a 404 registers this device again and retries once; a second 404 is reported")
    func registerPairAfterNotFound() async throws {
        let registration = RelayPairRegistration(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                                                 deviceA: "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f",
                                                 deviceB: "5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718", createdAt: 1,
                                                 attestation: "YQ", sigA: "Yg", sigB: "Yw")
        let posts = Counter()
        let once = ScriptedRelayHTTP { request in
            if request.url?.path == "/v1/pairs", request.httpMethod == "POST" {
                return posts.next() < 1 ? ScriptedRelayHTTP.error(404, "DEVICE_NOT_FOUND")
                    : ScriptedRelayHTTP.json(201, #"{"pair_id":"3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d","created_at":1}"#)
            }
            return Self.standard(request)
        }
        try await Self.client(once).registerPair(registration)
        #expect(once.paths.filter { !$0.contains("/auth/") }
            == ["POST /v1/pairs", "POST /v1/devices", "POST /v1/pairs"])
        let never = ScriptedRelayHTTP { request in
            request.url?.path == "/v1/pairs" ? ScriptedRelayHTTP.error(404, "DEVICE_NOT_FOUND") : Self.standard(request)
        }
        await #expect(throws: RelayAPIError.http(status: 404, code: .deviceNotFound, retryAfter: nil)) {
            try await Self.client(never).registerPair(registration)
        }
        #expect(never.paths.filter { $0 == "POST /v1/pairs" }.count == 2)
    }

    @Test("PAIR-03 API 3: a pair the relay does not know counts as revoked")
    func revokeUnknownPair() async throws {
        let http = ScriptedRelayHTTP { request in
            request.url?.path.hasSuffix("/revoke") == true ? ScriptedRelayHTTP.error(404, "DEVICE_NOT_FOUND")
                : Self.standard(request)
        }
        try await Self.client(http).revokePair(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", reason: .lostDevice)
        let body = try #require(http.requests.last?.httpBody)
        #expect(String(bytes: body, encoding: .utf8) == #"{"reason":"lost_device"}"#)
    }
}

/// Thread-safe counter for scripted answers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value - 1
    }
}
