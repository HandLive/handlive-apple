import Foundation
import HLCrypto
import HLProtocol

/// This device as the relay knows it (0.6.4, CONN-03 API 1).
public struct RelayIdentity: Sendable, Equatable {
    public let deviceId: String
    public let signingSeed: Data
    public let signingPublicKey: Data
    public let platform: CapabilityData.Platform
    public let appVersion: String

    public init(deviceId: String, signingSeed: Data, signingPublicKey: Data, platform: CapabilityData.Platform,
                appVersion: String) {
        self.deviceId = deviceId
        self.signingSeed = signingSeed
        self.signingPublicKey = signingPublicKey
        self.platform = platform
        self.appVersion = appVersion
    }
}

/// Why a relay call failed; the connection manager and the settings map these to CONN-03 E1–E7 and SET-02 E5–E7.
public enum RelayAPIError: Error, Sendable, Equatable {
    /// An HTTP error body of 0.8.2 (`code` `.unrecognized` for a code this version does not know or a missing body).
    case http(status: Int, code: RelayRestErrorCode, retryAfter: TimeInterval?)
    /// No answer, a timeout or a transport error (E1).
    case unreachable(String)
    /// The TLS chain carries none of the pinned keys (E7).
    case pinMismatch
    /// A 2xx answer that does not parse.
    case malformedResponse

    /// `410 DEVICE_REVOKED` (E3).
    public var isDeviceRevoked: Bool {
        if case .http(410, _, _) = self { return true }
        return false
    }

    var code: RelayRestErrorCode? {
        if case .http(_, let code, _) = self { return code }
        return nil
    }
}

/// The REST side of the relay (0.7.4) as the app and the connection manager use it; tests fake it.
public protocol RelayAPI: Sendable {
    /// `POST /v1/devices` (idempotent upsert).
    func registerDevice() async throws
    /// A JWT with more than 60 s left, fetched through challenge and signature when needed (0.6.4).
    func accessToken() async throws -> String
    func registerPair(_ registration: RelayPairRegistration) async throws
    func pairs() async throws -> RelayPairList
    func revokePair(pairId: String, reason: RelayPairRevokeRequest.Reason) async throws
    func updatePushToken(_ request: RelayPushTokenRequest) async throws
    func push(_ request: RelayPushRequest) async throws
    /// `DELETE /v1/devices/me?revoke_pairs=` (SET-02 API 2); a device the relay no longer knows counts as deleted.
    func deleteDevice(revokePairs: Bool) async throws
}

/// REST client of the relay: registration, the challenge–signature exchange for a 15-minute JWT, and the calls that
/// need it, with the retries of 0.6.4 step 3 and CONN-03 E2.
public actor RelayAPIClient: RelayAPI {
    /// A token is reused while more than this is left (CONN-03 step 4).
    static let tokenReuseMargin: TimeInterval = 60

    let configuration: RelayConfiguration
    let identity: RelayIdentity
    let transport: any RelayHTTPTransport
    let now: @Sendable () -> Date
    var token: (value: String, expiresAt: Date)?

    public init(configuration: RelayConfiguration, identity: RelayIdentity, transport: (any RelayHTTPTransport)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.identity = identity
        self.transport = transport ?? PinnedRelayHTTPTransport(configuration: configuration)
        self.now = now
    }

    // MARK: - Registration and token

    public func registerDevice() async throws {
        let ts = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        let message = try RelayAuthMessage.register(deviceId: identity.deviceId, signingPublicKey: identity.signingPublicKey,
                                                    platform: identity.platform.rawValue, ts: ts)
        let body = RelayDeviceRegistration(
            deviceId: identity.deviceId, platform: identity.platform.rawValue, appVersion: identity.appVersion,
            ikSigPub: Base64Coding.encodeB64u(identity.signingPublicKey), ts: ts,
            sig: Base64Coding.encodeB64u(try Ed25519.sign(message, seed: identity.signingSeed)))
        _ = try await call("POST", "devices", body: body, authorized: false, as: RelayDeviceRegistered.self)
    }

    public func accessToken() async throws -> String {
        try await accessToken(registerIfUnknown: true)
    }

    /// `registerIfUnknown = false` for deleting the device: a relay that no longer knows it means "already deleted".
    func accessToken(registerIfUnknown: Bool) async throws -> String {
        if let token, token.expiresAt.timeIntervalSince(now()) > Self.tokenReuseMargin { return token.value }
        do {
            return try await fetchToken()
        } catch let error as RelayAPIError where registerIfUnknown
            && (error.code == .deviceNotFound || error.code == .signatureInvalid) {
            try await registerDevice() // E2: register again, then retry once
            return try await fetchToken()
        } catch let error as RelayAPIError where error.code == .challengeExpired {
            return try await fetchToken()
        }
    }

    private func fetchToken() async throws -> String {
        let challenge = try await call("POST", "auth/challenge", body: RelayChallengeRequest(deviceId: identity.deviceId),
                                       authorized: false, as: RelayChallenge.self)
        guard let raw = try? Base64Coding.decodeB64u(challenge.challenge), raw.count == 32 else {
            throw RelayAPIError.malformedResponse
        }
        let message = try RelayAuthMessage.token(challenge: raw, deviceId: identity.deviceId)
        let request = RelayTokenRequest(deviceId: identity.deviceId, challenge: challenge.challenge,
                                        sig: Base64Coding.encodeB64u(try Ed25519.sign(message, seed: identity.signingSeed)))
        let issued = try await call("POST", "auth/token", body: request, authorized: false, as: RelayToken.self)
        token = (issued.accessToken, now().addingTimeInterval(TimeInterval(issued.expiresIn)))
        return issued.accessToken
    }

    /// Forgets the token (the relay rejected it, or the device left the relay).
    func dropToken() {
        token = nil
    }
}
