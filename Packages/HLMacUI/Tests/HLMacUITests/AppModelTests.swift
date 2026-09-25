import Foundation
import HLAppCore
import HLCrypto
import HLDesignSystem
import HLProtocol
import HLTransport
import Testing
@testable import HLMacUI

/// A secret store whose Keychain calls fail, like errSecMissingEntitlement (SET-03 E1).
private struct FailingSecretStore: SecretStore {
    func save(_ secret: Data, account: String) throws { throw CryptoError.keychain(status: -34018) }
    func load(account: String) throws -> Data? { throw CryptoError.keychain(status: -34018) }
    func delete(account: String) throws { throw CryptoError.keychain(status: -34018) }
    func deleteAll() throws { throw CryptoError.keychain(status: -34018) }
}

/// Discovery and network that never report anything: the model's manager stays idle in tests.
private struct SilentDiscovery: LANDiscovering {
    func events() -> AsyncStream<DiscoveryEvent> { AsyncStream { _ in } }
}

private struct SilentNetwork: NetworkMonitoring {
    func updates() -> AsyncStream<NetworkPathStatus> { AsyncStream { _ in } }
}

@MainActor
private func makeModel(secrets: any SecretStore = InMemorySecretStore()) -> AppModel {
    let suite = "app.handlive.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppModel(settings: AppSettings(defaults: defaults), secrets: secrets,
                    device: LocalDevice(appVersion: "1.0.0 (1)", osVersion: "15.6", model: "Mac15,3", name: "Mac",
                                        platform: .macos),
                    bundleIdentifier: "app.handlive.tests.\(UUID().uuidString)") {
        ConnectionManager(localCapability: $0, discovery: SilentDiscovery(), network: SilentNetwork())
    }
}

@Suite("Mac app model")
@MainActor
struct AppModelTests {
    @Test("Launch creates the keys (SET-03 step 2) and reaches ready without a pair")
    func launch() {
        let model = makeModel()
        model.launch()
        #expect(model.phase == .ready)
        #expect(model.deviceId != nil)
        #expect(model.pairedDevice == nil)
        #expect(!model.setupCompleted)
        model.completeSetup()
        #expect(model.setupCompleted)
    }

    @Test("A Keychain that refuses the keys → keysFailed with Try Again (SET-03 E1)")
    func keysFailed() {
        let model = makeModel(secrets: FailingSecretStore())
        model.launch()
        #expect(model.phase == .keysFailed)
        model.retryKeys()
        #expect(model.phase == .keysFailed)
    }

    @Test("Settings setters persist and clamp; clipboard needs a connected phone")
    func settings() {
        let model = makeModel()
        model.launch()
        model.setAutoClearSeconds(300)
        #expect(model.autoClearSeconds == 300)
        model.setAutoClearSeconds(7)
        #expect(model.autoClearSeconds == 60)
        model.setSendImages(false)
        #expect(!model.sendImages)
        #expect(!model.canSendClipboard)
        #expect(model.clipboardUnavailableReason == nil) // no phone yet
    }

    @Test("Link status → StatusIndicator state (0.11, PAIR-02 field 4)")
    func statusMapping() {
        #expect(HLConnectionStatus(link: LinkStatus(state: .idle(.notPaired)), lastSeen: nil) == .notPaired)
        #expect(HLConnectionStatus(link: LinkStatus(state: .idle(.needsRepair)), lastSeen: nil) == .needsRepair)
        #expect(HLConnectionStatus(link: LinkStatus(state: .backoff), lastSeen: nil) == .networkLost)
        #expect(HLConnectionStatus(link: LinkStatus(state: .handshaking(.lan)), lastSeen: nil) == .connecting)
        #expect(HLConnectionStatus(link: LinkStatus(state: .connected(.lan)), lastSeen: nil) == .connectedWiFi)
        #expect(HLConnectionStatus(link: LinkStatus(state: .connected(.relay)), lastSeen: nil) == .connectedInternet)
        let offline = HLConnectionStatus(link: LinkStatus(state: .waitingPeer), lastSeen: 1_727_151_000_000)
        guard case .phoneOffline(let time?) = offline else {
            Issue.record("no last-seen time")
            return
        }
        #expect(!time.isEmpty)
        #expect(HLConnectionStatus.connectedWiFi.menuBarSymbolName == "antenna.radiowaves.left.and.right")
        #expect(HLConnectionStatus.networkLost.menuBarSymbolName == "antenna.radiowaves.left.and.right.slash")
    }

    @Test("Unpairing without a session removes the PRK and the record (PAIR-03 flow B)")
    func unpairOffline() async throws {
        let secrets = InMemorySecretStore()
        let model = makeModel(secrets: secrets)
        model.launch()
        let record = PairedDeviceRecord(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", peerDeviceId: HLUUID.v7(),
                                        peerName: "Pixel 8", peerModel: nil, peerSigningPublicKey: Data(count: 32),
                                        peerKeyAgreementPublicKey: Data(count: 32), peerCertificateSHA256: Data(count: 32),
                                        attestation: Data(), signatureSelf: Data(), signaturePeer: Data(), createdAt: 1)
        try model.store?.upsert(record)
        try secrets.save(Data(count: 32), account: record.pairId)
        model.pairedDevice = record
        #expect(await model.unpair() == .donePendingRemote)
        #expect(model.pairedDevice == nil)
        #expect(try secrets.load(account: record.pairId) == nil)
        #expect(try model.store?.all().isEmpty == true)
    }
}
