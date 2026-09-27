import Foundation
import HLAppCore
import HLCrypto
import HLProtocol
import HLSMS
import HLTransport

/// The dev client's state in its scratch directory, laid out like the Mac app's: settings (`settings.plist` instead of
/// the app's defaults), the keys (files instead of the Keychain), the encrypted pair store and the SQLCipher database
/// that holds SMS and the call log. `setup.started_at` in the settings keeps the keys across runs (SET-03 API 1).
@MainActor
final class DevWorkspace {
    struct Refusal: Error, CustomStringConvertible {
        let description: String
    }

    let options: DevOptions
    let settings: AppSettings
    let secrets: FileSecretStore
    let keys: DeviceIdentityKeys
    let store: PairedDeviceStore
    let device: LocalDevice

    init(options: DevOptions) throws {
        try Self.refuseWorkspace(options.scratch)
        try FileManager.default.createDirectory(at: options.scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        self.options = options
        guard let defaults = UserDefaults(suiteName: options.scratch.appendingPathComponent("settings").path) else {
            throw Refusal(description: "cannot open the settings in \(options.scratch.path)")
        }
        settings = AppSettings(defaults: defaults)
        secrets = try FileSecretStore(directory: options.scratch.appendingPathComponent("secrets", isDirectory: true))
        keys = try DeviceIdentityKeys.loadOrCreate(secrets: secrets, settings: settings)
        BenchLog.configure(deviceId: keys.deviceId, role: .macos)
        store = PairedDeviceStore(fileURL: options.scratch.appendingPathComponent("paired-devices.bin"),
                                  databaseKey: keys.databaseKey)
        let current = LocalDevice.current(name: options.name, platform: .macos)
        device = LocalDevice(appVersion: "0.0.1 (1)", osVersion: current.osVersion, model: current.model,
                             name: options.name, platform: .macos)
    }

    /// Keys and pair state never go into the repository: the scratch directory must be outside the workspace.
    static func refuseWorkspace(_ scratch: URL) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let scratchPath = scratch.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        if scratchPath.hasPrefix(rootPath) {
            throw Refusal(description: "--scratch must be outside the HandLive workspace (\(rootPath))")
        }
    }

    /// This Mac as `pair/hello` presents it (PAIR-01 API 2).
    func pairingIdentity() -> PairingIdentity {
        PairingIdentity(deviceId: keys.deviceId, name: PairingInvite.fittedName(device.name), platform: .macos,
                        model: device.model, signingSeed: keys.signingSeed, signingPublicKey: keys.signingPublicKey,
                        dhPrivateKey: keys.keyAgreementPrivateKey, dhPublicKey: keys.keyAgreementPublicKey)
    }

    var pairedDevice: PairedDeviceRecord? { try? store.active() }

    /// The active pair with its `PRK`, reached at the forwarded address through the `last_host` fast path (CONN-01
    /// step 2): there is no mDNS between macOS and the emulator.
    func activePhone() -> PairedPhone? {
        guard let record = pairedDevice,
              let prk = try? secrets.load(account: SecretAccount.pairKey(pairId: record.pairId)) else { return nil }
        var phone = record.pairedPhone(clientDeviceId: keys.deviceId, prk: prk)
        phone.lastHost = options.host
        phone.lastPort = options.port
        return phone
    }

    /// PAIR-01 API 5 logic 2, as the apps do it: `PRK` first, then the record, and only then success.
    func storePair(_ result: PairingResult) throws {
        let account = SecretAccount.pairKey(pairId: result.pairId)
        try secrets.save(result.prk, account: account)
        var record = PairedDeviceRecord(
            pairId: result.pairId, peerDeviceId: result.phoneDeviceId, peerName: result.phoneName,
            peerModel: result.phoneModel, peerSigningPublicKey: result.phoneSigningPublicKey,
            peerKeyAgreementPublicKey: result.phoneDHPublicKey, peerCertificateSHA256: result.certificateSHA256,
            attestation: result.attestation, signatureSelf: result.signatureSelf, signaturePeer: result.signaturePeer,
            createdAt: result.createdAt)
        record.lastHost = options.host
        record.lastPort = options.port
        do {
            try store.upsert(record)
        } catch {
            try? secrets.delete(account: account)
            throw error
        }
    }

    func updatePair(_ change: (inout PairedDeviceRecord) -> Void) {
        guard let pairId = pairedDevice?.pairId else { return }
        try? store.update(pairId: pairId, change)
    }

    /// The SQLCipher database of SMS and the call log, keyed with `db_key` (0.6.1).
    func openDatabase() throws -> SmsDatabase {
        try SmsDatabase(url: options.scratch.appendingPathComponent("handlive.sqlite"), key: keys.databaseKey)
    }
}
