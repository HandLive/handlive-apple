import Foundation
import HLAppCore
import HLCrypto
import HLProtocol
import HLTransport
@testable import HLiOSUI

/// Discovery and network that never report anything: the model's manager stays idle in tests.
struct SilentDiscovery: LANDiscovering {
    func events() -> AsyncStream<DiscoveryEvent> { AsyncStream { _ in } }
}

struct SilentNetwork: NetworkMonitoring {
    func updates() -> AsyncStream<NetworkPathStatus> { AsyncStream { _ in } }
}

/// `UIPasteboard` as the engine sees it on iPhone: a `changeCount`, writes recorded, never a content read.
@MainActor
final class StubIOSPasteboard: ClipboardAccess {
    private(set) var changeCount = 1
    private(set) var writes: [ClipContent] = []
    private(set) var contentReads = 0

    func userCopied() {
        changeCount += 1
    }

    func firstItemTypes() -> [String]? {
        contentReads += 1
        return nil
    }

    func string(forType type: String) -> String? {
        contentReads += 1
        return nil
    }

    func data(forType type: String) -> Data? {
        contentReads += 1
        return nil
    }

    func write(_ content: ClipContent, clipId: String, sensitive: Bool) -> Int? {
        writes.append(content)
        changeCount += 1
        return changeCount
    }

    func clear() -> Int {
        changeCount += 1
        return changeCount
    }
}

/// Notifications recorded instead of shown.
@MainActor
final class StubIOSNotifications: IOSNotifying {
    private(set) var removed: [(threadId: Int64, upToTs: Int64?)] = []
    private(set) var badges: [Int] = []
    private(set) var notSentYet: [Int64] = []
    private(set) var removedAllSms = 0
    private(set) var removedGeneric = 0
    private(set) var removedEverything = 0

    func remove(pairId: String, threadId: Int64, upToTs: Int64?) { removed.append((threadId, upToTs)) }
    func removeAllSms() { removedAllSms += 1 }
    func removeGeneric() { removedGeneric += 1 }
    func removeEverything() { removedEverything += 1 }
    func setBadge(_ count: Int) { badges.append(count) }
    func postNotSentYet(pairId: String, threadId: Int64) { notSentYet.append(threadId) }
    var answer = NotificationPermission.allowed
    private(set) var requests = 0

    func permission() async -> NotificationPermission { requests == 0 ? .notDetermined : answer }

    func requestPermission() async -> NotificationPermission {
        requests += 1
        return answer
    }
}

/// The relay's REST side as a script: calls recorded, `reachable = false` fails like no network.
final class ScriptedRelayAPI: RelayAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var reachableValue = true
    private var log: [String] = []
    private var tokens: [RelayPushTokenRequest] = []

    var reachable: Bool {
        get { lock.withLock { reachableValue } }
        set { lock.withLock { reachableValue = newValue } }
    }

    var calls: [String] { lock.withLock { log } }
    var pushTokens: [RelayPushTokenRequest] { lock.withLock { tokens } }

    private func record(_ call: String) throws {
        try lock.withLock {
            log.append(call)
            if !reachableValue { throw RelayAPIError.unreachable("offline") }
        }
    }

    func registerDevice() async throws { try record("registerDevice") }
    func accessToken() async throws -> String {
        try record("accessToken")
        return "jwt"
    }
    func registerPair(_ registration: RelayPairRegistration) async throws { try record("registerPair") }
    func pairs() async throws -> RelayPairList {
        try record("pairs")
        return RelayPairList(pairs: [])
    }
    func revokePair(pairId: String, reason: RelayPairRevokeRequest.Reason) async throws {
        try record("revokePair \(reason.rawValue)")
    }
    func updatePushToken(_ request: RelayPushTokenRequest) async throws {
        try record("updatePushToken")
        lock.withLock { tokens.append(request) }
    }
    func push(_ request: RelayPushRequest) async throws { try record("push") }
    func deleteDevice(revokePairs: Bool) async throws { try record("deleteDevice revoke_pairs=\(revokePairs)") }
}

/// A relay WebSocket that never opens: the tests stay on the (silent) LAN.
struct ClosedRelaySockets: RelaySocketOpening {
    func open(token: String, timeout: Duration) async throws -> any MessageChannel {
        throw RelayAPIError.unreachable("closed")
    }
}

@MainActor
func makeIOSModel(secrets: any SecretStore = InMemorySecretStore(), pasteboard: StubIOSPasteboard = StubIOSPasteboard(),
                  notifications: StubIOSNotifications = StubIOSNotifications(),
                  relay: ScriptedRelayAPI? = nil, platform: CapabilityData.Platform = .ios) -> IOSAppModel {
    let defaults = UserDefaults(suiteName: "app.handlive.ios.tests.\(UUID().uuidString)")!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handlive-ios-tests-\(UUID().uuidString)")
    return IOSAppModel(settings: AppSettings(defaults: defaults), secrets: secrets,
                       device: LocalDevice(appVersion: "1.0.0 (1)", osVersion: "18.0", model: "iPhone15,2",
                                           name: "iPhone của Lan", platform: platform),
                       pairStoreURL: folder.appendingPathComponent("paired-devices.bin"),
                       smsDatabaseURL: folder.appendingPathComponent("handlive.sqlite"),
                       pasteboard: pasteboard, notifications: notifications, pushProvider: .apnsSandbox,
                       pushTopic: "app.handlive.ios",
                       makeRelay: { _ in relay.map { RelayServices(api: $0, sockets: ClosedRelaySockets()) } },
                       makeManager: { capability, _ in
                           ConnectionManager(localCapability: capability, discovery: SilentDiscovery(),
                                             network: SilentNetwork())
                       })
}

/// A pairing result as PAIR-01 hands it over.
func pairingResult(name: String = "Pixel của Lan") -> PairingResult {
    PairingResult(pairId: UUID().uuidString.lowercased(), createdAt: 1_727_150_003_210,
                  phoneDeviceId: "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f", phoneName: name, phoneModel: "Pixel 8",
                  phoneOSVersion: "15", phoneSigningPublicKey: Data(repeating: 0x33, count: 32),
                  phoneDHPublicKey: Data(repeating: 0x44, count: 32), certificateSHA256: Data(repeating: 0x55, count: 32),
                  attestation: Data(repeating: 0x01, count: 127), signatureSelf: Data(repeating: 0x02, count: 64),
                  signaturePeer: Data(repeating: 0x03, count: 64), prk: Data(repeating: 0x99, count: 32))
}

/// Polls `condition` on the main actor for up to three seconds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
