import Foundation
import HLAppCore
import HLCrypto
import HLProtocol
import HLTransport
@testable import HLMacUI

/// A secret store whose Keychain calls fail, like errSecMissingEntitlement (SET-03 E1).
struct FailingSecretStore: SecretStore {
    func save(_ secret: Data, account: String) throws { throw CryptoError.keychain(status: -34018) }
    func load(account: String) throws -> Data? { throw CryptoError.keychain(status: -34018) }
    func delete(account: String) throws { throw CryptoError.keychain(status: -34018) }
    func deleteAll() throws { throw CryptoError.keychain(status: -34018) }
}

/// Discovery and network that never report anything: the model's manager stays idle in tests.
struct SilentDiscovery: LANDiscovering {
    func events() -> AsyncStream<DiscoveryEvent> { AsyncStream { _ in } }
}

struct SilentNetwork: NetworkMonitoring {
    func updates() -> AsyncStream<NetworkPathStatus> { AsyncStream { _ in } }
}

@MainActor
func makeModel(secrets: any SecretStore = InMemorySecretStore()) -> AppModel {
    let suite = "app.handlive.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppModel(settings: AppSettings(defaults: defaults), secrets: secrets,
                    device: LocalDevice(appVersion: "1.0.0 (1)", osVersion: "15.6", model: "Mac15,3", name: "Mac",
                                        platform: .macos),
                    pairStoreURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("handlive-tests-\(UUID().uuidString)/paired-devices.bin")) {
        ConnectionManager(localCapability: $0, discovery: SilentDiscovery(), network: SilentNetwork())
    }
}
