import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLAppCore

private func freshDefaults() -> UserDefaults {
    let name = "app.handlive.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Settings (0.9.5, SET-02)")
struct AppSettingsTests {
    @Test("Registered defaults follow 0.9.5")
    func defaults() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.clipboardEnabled && settings.sendImages && settings.blockSensitive && settings.relayEnabled)
        #expect(settings.showInMenuBar)
        #expect(settings.autoClearSeconds == 60)
        #expect(!settings.bool(.featureCallAudio) && !settings.bool(.featureCamera))
        #expect(settings.setupStartedAt == nil && settings.setupCompletedAt == nil)
    }

    @Test("Auto-clear keeps only 0, 60 and 300 seconds; timestamps round-trip")
    func values() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.autoClearSeconds = 300
        #expect(settings.autoClearSeconds == 300)
        settings.autoClearSeconds = 0
        #expect(settings.autoClearSeconds == 0)
        settings.autoClearSeconds = 42
        #expect(settings.autoClearSeconds == 60)
        settings.setupCompletedAt = 1_727_151_000_123
        #expect(settings.setupCompletedAt == 1_727_151_000_123)
        settings.setupCompletedAt = nil
        #expect(settings.setupCompletedAt == nil)
    }

    @Test("Delete All removes every key; the 0.9.5 defaults apply again")
    func removeAll() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.relayEnabled = false
        settings.smsPreview = false
        settings.setupCompletedAt = 1_727_151_000_123
        settings.removeAll()
        #expect(settings.relayEnabled && settings.smsPreview && settings.setupCompletedAt == nil)
    }
}

@Suite("Identity keys (SET-03 API 1)")
struct DeviceIdentityKeysTests {
    @Test("A fresh install clears leftovers, creates ik_sig, ik_dh, db_key and records setup.started_at")
    func freshInstall() throws {
        let secrets = InMemorySecretStore()
        try secrets.save(Data([1]), account: "stale-pair-id")
        let settings = AppSettings(defaults: freshDefaults())
        let keys = try DeviceIdentityKeys.loadOrCreate(secrets: secrets, settings: settings, now: 1_000)
        #expect(try secrets.load(account: "stale-pair-id") == nil)
        #expect(settings.setupStartedAt == 1_000)
        #expect(try secrets.load(account: SecretAccount.signingKey) == keys.signingSeed)
        #expect(keys.databaseKey.count == 32 && keys.signingPublicKey.count == 32)
        #expect(DeviceIdentity.matches(deviceId: keys.deviceId, signingPublicKey: keys.signingPublicKey))
        let again = try DeviceIdentityKeys.loadOrCreate(secrets: secrets, settings: settings)
        #expect(again == keys)
    }

    @Test("Keys missing after setup started → keysMissing (setup starts over)")
    func missingKeys() throws {
        let settings = AppSettings(defaults: freshDefaults())
        settings.setupStartedAt = 5
        #expect(throws: IdentityError.keysMissing) {
            _ = try DeviceIdentityKeys.loadOrCreate(secrets: InMemorySecretStore(), settings: settings)
        }
    }
}

@Suite("Local capability (0.7.2, SET-02 API 1)")
struct LocalCapabilityTests {
    @Test("Clipboard and relay follow the settings; Sync Images off leaves only text/plain")
    func capability() {
        let settings = AppSettings(defaults: freshDefaults())
        let device = LocalDevice(appVersion: "1.0.0 (100)", osVersion: "15.6", model: "Mac15,3", name: "Mac", platform: .macos)
        var capability = device.capability(settings: settings)
        #expect(capability.features.clipboard?.mimes == ["text/plain", "image/png", "image/jpeg"])
        #expect(capability.features.clipboard?.autoSend == true)
        #expect(capability.features.relay?.enabled == true)
        #expect(capability.features.sms == SmsFeature(enabled: true) && capability.features.camera == nil)
        settings.sendImages = false
        settings.clipboardEnabled = false
        settings.smsEnabled = false
        capability = device.capability(settings: settings)
        #expect(capability.features.clipboard?.mimes == ["text/plain"])
        #expect(capability.features.clipboard?.enabled == false)
        #expect(capability.features.sms?.enabled == false && capability.features.sms?.notify == nil)
    }

    @Test("iPhone and iPad add sms.notify, which tells the phone whether to push new messages (SET-02 field 8)")
    func mobileNotify() {
        let settings = AppSettings(defaults: freshDefaults())
        let phone = LocalDevice(appVersion: "1.0.0 (100)", osVersion: "18.6", model: "iPhone16,1", name: "iPhone",
                                platform: .ios)
        #expect(phone.capability(settings: settings).features.sms == SmsFeature(enabled: true, notify: true))
        settings.smsNotify = false
        #expect(phone.capability(settings: settings).features.sms?.notify == false)
    }

    @Test("The device name sent at pairing is cut to 64 characters")
    func nameLimit() {
        let device = LocalDevice(appVersion: "", osVersion: "", model: "", name: String(repeating: "a", count: 80),
                                 platform: .macos)
        #expect(device.name.count == 64)
        #expect(!LocalDevice.hardwareModel().isEmpty)
    }
}

@Suite("Paired device store")
struct PairedDeviceStoreTests {
    private func record(_ id: String) -> PairedDeviceRecord {
        PairedDeviceRecord(pairId: id, peerDeviceId: "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f", peerName: "Pixel 8",
                           peerModel: "Pixel 8", peerSigningPublicKey: Data(count: 32),
                           peerKeyAgreementPublicKey: Data(count: 32),
                           peerCertificateSHA256: Data(repeating: 1, count: 32), attestation: Data("HLPAIR1".utf8),
                           signatureSelf: Data(count: 64), signaturePeer: Data(count: 64), createdAt: 1)
    }

    @Test("Encrypted round trip; a wrong key cannot read it; tombstones are not active")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl-\(UUID().uuidString)/pairs.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = Data(repeating: 7, count: 32)
        let store = PairedDeviceStore(fileURL: url, databaseKey: key)
        #expect(try store.all().isEmpty)
        try store.upsert(record("3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"))
        try store.update(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d") { $0.lastHost = "192.168.1.23" }
        #expect(try store.active()?.lastHost == "192.168.1.23")
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("Pixel 8".utf8)) == nil) // encrypted at rest
        #expect(throws: (any Error).self) { _ = try PairedDeviceStore(fileURL: url, databaseKey: Data(count: 32)).all() }
        try store.update(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d") { $0.revokedAt = 9 }
        #expect(try store.active() == nil)
        #expect(try store.all().count == 1)
        try store.remove(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")
        #expect(try store.all().isEmpty)
    }

    @Test("Security code: the first 8 lowercase hex of SHA-256(attestation), as on Android (PAIR-02 field 10)")
    func securityCode() throws {
        var pair = record("x")
        // The attestation of the Android PairingAuthDerivationTest; its code there is "fc647e0b".
        let hex = "484c50414952313f2b1c4d5e6f4a7b8c9d0e1f2a3b4c5d8c7d6e5f4a3b8c2d9e1f0a1b2c3d4e5f5b1f8c2e9a4d8e6f"
            + "a1b2c3d4e5f60718" + String(repeating: "33", count: 32) + String(repeating: "11", count: 32) + "000001922229940a"
        pair.attestation = Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0
        })
        #expect(pair.securityCode == "fc647e0b")
    }
}
