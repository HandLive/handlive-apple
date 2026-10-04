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
        // Only this build's keychain: a build signed the other way finds its keys again (SET-03 API 1 logic 1).
        #expect(secrets.everyKeychainDeletions == 0)
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
    @Test("Clipboard and relay follow the settings; Sync Images off leaves text/plain and text/html")
    func capability() {
        let settings = AppSettings(defaults: freshDefaults())
        let device = LocalDevice(appVersion: "1.0.0 (100)", osVersion: "15.6", model: "Mac15,3", name: "Mac", platform: .macos)
        var capability = device.capability(settings: settings)
        #expect(capability.features.clipboard?.mimes == ["text/plain", "text/html", "image/png", "image/jpeg"])
        #expect(capability.features.clipboard?.autoSend == true)
        #expect(capability.features.relay?.enabled == true)
        #expect(capability.features.sms == SmsFeature(enabled: true) && capability.features.camera == nil)
        settings.sendImages = false
        settings.clipboardEnabled = false
        settings.smsEnabled = false
        capability = device.capability(settings: settings)
        #expect(capability.features.clipboard?.mimes == ["text/plain", "text/html"])
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

    @Test("Calls follow feature.call; iPhone and iPad add call.notify, which decides the call pushes (SET-02 field 11)")
    func calls() {
        let settings = AppSettings(defaults: freshDefaults())
        let mac = LocalDevice(appVersion: "1.0.0 (100)", osVersion: "15.6", model: "Mac15,3", name: "Mac", platform: .macos)
        #expect(mac.capability(settings: settings).features.call == CallFeature(enabled: true, appCalls: true))
        let phone = LocalDevice(appVersion: "1.0.0 (100)", osVersion: "18.6", model: "iPhone16,1", name: "iPhone",
                                platform: .ios)
        #expect(phone.capability(settings: settings).features.call
            == CallFeature(enabled: true, notify: true, appCalls: false))
        settings.callNotify = false
        settings.callsEnabled = false
        #expect(phone.capability(settings: settings).features.call
            == CallFeature(enabled: false, notify: false, appCalls: false))
        #expect(settings.callRingtone && settings.quickReplies == nil)
    }

    @Test("Calls from other apps: call.app_calls drives the Mac's app_calls, on by default; iPhone and iPad say false")
    func appCalls() {
        let settings = AppSettings(defaults: freshDefaults())
        let mac = LocalDevice(appVersion: "1.0.0 (100)", osVersion: "15.6", model: "Mac15,3", name: "Mac", platform: .macos)
        #expect(settings.callAppCalls && SettingsKey.callAppCalls.rawValue == "call.app_calls")
        #expect(mac.capability(settings: settings).features.call?.appCalls == true)
        settings.callAppCalls = false
        #expect(mac.capability(settings: settings).features.call?.appCalls == false)
        // 0.7.2: the Mac says `feature.call` ∧ `call.app_calls`, so the Calls switch off turns app calls off too.
        settings.callAppCalls = true
        settings.callsEnabled = false
        #expect(mac.capability(settings: settings).features.call == CallFeature(enabled: false, appCalls: false))
        settings.callAppCalls = false
        #expect(mac.capability(settings: settings).features.call?.appCalls == false)
        settings.callsEnabled = true
        settings.callAppCalls = true
        #expect(mac.capability(settings: settings).features.call == CallFeature(enabled: true, appCalls: true))
        for platform in [CapabilityData.Platform.ios, .ipados] {
            let mobile = LocalDevice(appVersion: "1.0.0 (100)", osVersion: "18.6", model: "iPad14,1", name: "iPad",
                                     platform: platform)
            settings.callAppCalls = true // whatever the stored value, a mobile device cannot show them
            #expect(mobile.capability(settings: settings).features.call?.appCalls == false)
        }
        settings.removeAll()
        #expect(settings.callAppCalls) // Delete All HandLive Data: back to the default
    }

    @Test("sms.peer_can_send keeps each pair's copy for the extension; Delete All removes it")
    func peerCanSend() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.peerCanSend(pairId: "a") == nil)
        settings.setPeerCanSend(true, pairId: "a")
        settings.setPeerCanSend(false, pairId: "b")
        #expect(settings.peerCanSend(pairId: "a") == true && settings.peerCanSend(pairId: "b") == false)
        settings.setPeerCanSend(nil, pairId: "a")
        #expect(settings.peerCanSend(pairId: "a") == nil)
        settings.removeAll()
        #expect(settings.peerCanSend(pairId: "b") == nil)
    }

    @Test("Quick replies keep at most 6 templates of 160 characters")
    func quickReplies() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.quickReplies = (1...8).map { "\($0)" + String(repeating: "x", count: 200) }
        #expect(settings.quickReplies?.count == 6 && settings.quickReplies?.allSatisfy { $0.count == 160 } == true)
        settings.removeAll()
        #expect(settings.quickReplies == nil)
    }

    @Test("The device name sent at pairing is cut to 64 characters")
    func nameLimit() {
        let device = LocalDevice(appVersion: "", osVersion: "", model: "", name: String(repeating: "a", count: 80),
                                 platform: .macos)
        #expect(device.name.count == 64)
        #expect(!LocalDevice.hardwareModel().isEmpty)
    }
}
