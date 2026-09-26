import Foundation
import HLAppCore
import HLCrypto
import HLProtocol
import HLSMS
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

/// A clipboard that never touches the Mac's real pasteboard.
@MainActor
final class StubPasteboard: ClipboardAccess {
    private(set) var changeCount = 1
    private var text: String?

    func copy(_ value: String) {
        text = value
        changeCount += 1
    }

    func firstItemTypes() -> [String]? { text == nil ? nil : [PasteboardTypeID.text] }
    func string(forType type: String) -> String? { type == PasteboardTypeID.text ? text : nil }
    func data(forType type: String) -> Data? { nil }

    func write(_ content: ClipContent, clipId: String, sensitive: Bool) -> Int? {
        if case .text(let value) = content { text = value }
        changeCount += 1
        return changeCount
    }

    func clear() -> Int {
        text = nil
        changeCount += 1
        return changeCount
    }
}

/// Notifications recorded instead of posted (a test process has no notification center).
@MainActor
final class StubAlerts: ClipboardAlerting {
    var onSendAnyway: () -> Void = {}
    var onSendAgain: () -> Void = {}
    var onSmsResponse: (SmsNotificationResponse) -> Void = { _ in }
    private(set) var posted: [ClipboardAlert] = []

    func post(_ alert: ClipboardAlert) {
        posted.append(alert)
    }
}

@MainActor
func makeModel(secrets: any SecretStore = InMemorySecretStore(), pasteboard: StubPasteboard = StubPasteboard(),
               alerts: StubAlerts = StubAlerts(), sms: StubSmsNotifier = StubSmsNotifier()) -> AppModel {
    let suite = "app.handlive.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppModel(settings: AppSettings(defaults: defaults), secrets: secrets,
                    device: LocalDevice(appVersion: "1.0.0 (1)", osVersion: "15.6", model: "Mac15,3", name: "Mac",
                                        platform: .macos),
                    pairStoreURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("handlive-tests-\(UUID().uuidString)/paired-devices.bin"),
                    smsDatabaseURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("handlive-tests-\(UUID().uuidString)/handlive.sqlite"),
                    pasteboard: pasteboard, alerts: alerts, smsNotifier: sms, relayConfiguration: nil) { capability, _ in
        ConnectionManager(localCapability: capability, discovery: SilentDiscovery(), network: SilentNetwork())
    }
}

/// SMS notifications recorded instead of posted.
@MainActor
final class StubSmsNotifier: SmsNotifying {
    private(set) var posted: [SmsIncoming] = []
    private(set) var previews: [Bool] = []
    private(set) var removed: [(threadId: Int64, upToTs: Int64?)] = []
    private(set) var removedAll = 0

    func post(_ incoming: SmsIncoming, showPreview: Bool) {
        posted.append(incoming)
        previews.append(showPreview)
    }

    func remove(pairId: String, threadId: Int64, upToTs: Int64?) {
        removed.append((threadId, upToTs))
    }

    func removeAll() {
        removedAll += 1
    }
}
