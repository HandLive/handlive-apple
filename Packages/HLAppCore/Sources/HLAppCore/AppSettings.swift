import Foundation

/// Settings keys of 00-common-specs 0.9.5 that the Apple apps use.
public enum SettingsKey: String, CaseIterable, Sendable {
    case setupStartedAt = "setup.started_at"
    case setupCompletedAt = "setup.completed_at"
    case featureClipboard = "feature.clipboard"
    case featureSms = "feature.sms"
    case featureCall = "feature.call"
    case featureCallAudio = "feature.call_audio"
    case featureCamera = "feature.camera"
    case relayEnabled = "relay.enabled"
    case clipSendImages = "clip.send_images"
    case clipBlockSensitive = "clip.block_sensitive"
    case clipAutoClearSeconds = "clip.auto_clear_s"
    case smsNotify = "sms.notify"
    case smsPreview = "sms.preview"
    case callNotify = "call.notify"
    case callRingtone = "call.ringtone"
    case callAudioAllowOpusFallback = "call_audio.allow_opus_fallback"
    case callAudioPhoneBluetoothAddress = "call_audio.phone_bt_address"
    case cameraDefaultCamera = "cam.default_camera"
    case cameraDefaultQuality = "cam.default_quality"
    case cameraUsbBoost = "cam.usb_boost"
    case cameraUsbWizardDismissed = "cam.usb_wizard_dismissed"
    case menuBarExtra = "mac.menu_bar_extra"
}

/// Settings of this device in `UserDefaults` (SET-02). Defaults are registered at every launch (SET-03 Query);
/// settings belong to the device and are never synced — the phone only sees them through capability.
public final class AppSettings: @unchecked Sendable {
    /// `clip.auto_clear_s` choices: off, 1 minute, 5 minutes (CLIP-05 field 1).
    public static let autoClearChoices = [0, 60, 300]

    /// 0.9.5 defaults (SET-03 Query; the Mac also registers the call-audio and camera keys).
    public static var registeredDefaults: [String: Any] { [
        SettingsKey.featureClipboard.rawValue: true, SettingsKey.featureSms.rawValue: true,
        SettingsKey.featureCall.rawValue: true, SettingsKey.relayEnabled.rawValue: true,
        SettingsKey.clipSendImages.rawValue: true, SettingsKey.clipBlockSensitive.rawValue: true,
        SettingsKey.clipAutoClearSeconds.rawValue: 60, SettingsKey.smsNotify.rawValue: true,
        SettingsKey.smsPreview.rawValue: true, SettingsKey.callNotify.rawValue: true,
        SettingsKey.callRingtone.rawValue: true, SettingsKey.featureCallAudio.rawValue: false,
        SettingsKey.callAudioAllowOpusFallback.rawValue: true, SettingsKey.callAudioPhoneBluetoothAddress.rawValue: "",
        SettingsKey.featureCamera.rawValue: false, SettingsKey.cameraDefaultCamera.rawValue: "front",
        SettingsKey.cameraDefaultQuality.rawValue: "auto", SettingsKey.cameraUsbBoost.rawValue: true,
        SettingsKey.cameraUsbWizardDismissed.rawValue: false, SettingsKey.menuBarExtra.rawValue: true,
    ] }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.registeredDefaults)
    }

    /// "Delete All HandLive Data" (SET-02 API 7): every key of 0.9.5 goes; the registered defaults apply again.
    public func removeAll() {
        for key in SettingsKey.allCases { defaults.removeObject(forKey: key.rawValue) }
    }

    public func bool(_ key: SettingsKey) -> Bool { defaults.bool(forKey: key.rawValue) }
    public func set(_ value: Bool, _ key: SettingsKey) { defaults.set(value, forKey: key.rawValue) }

    public var clipboardEnabled: Bool {
        get { bool(.featureClipboard) }
        set { set(newValue, .featureClipboard) }
    }

    public var sendImages: Bool {
        get { bool(.clipSendImages) }
        set { set(newValue, .clipSendImages) }
    }

    public var blockSensitive: Bool {
        get { bool(.clipBlockSensitive) }
        set { set(newValue, .clipBlockSensitive) }
    }

    /// `feature.sms` (SET-02 field 7).
    public var smsEnabled: Bool {
        get { bool(.featureSms) }
        set { set(newValue, .featureSms) }
    }

    /// `sms.notify` (field 8): iOS advertises it in its capability; the Mac only decides locally.
    public var smsNotify: Bool {
        get { bool(.smsNotify) }
        set { set(newValue, .smsNotify) }
    }

    /// `sms.preview` (field 9): the extension reads it from the App Group suite.
    public var smsPreview: Bool {
        get { bool(.smsPreview) }
        set { set(newValue, .smsPreview) }
    }

    public var relayEnabled: Bool {
        get { bool(.relayEnabled) }
        set { set(newValue, .relayEnabled) }
    }

    public var showInMenuBar: Bool {
        get { bool(.menuBarExtra) }
        set { set(newValue, .menuBarExtra) }
    }

    /// Seconds before a received clip is cleared; only 0, 60 and 300 are kept (anything else reads as 60).
    public var autoClearSeconds: Int {
        get {
            let value = defaults.integer(forKey: SettingsKey.clipAutoClearSeconds.rawValue)
            return Self.autoClearChoices.contains(value) ? value : 60
        }
        set {
            let value = Self.autoClearChoices.contains(newValue) ? newValue : 60
            defaults.set(value, forKey: SettingsKey.clipAutoClearSeconds.rawValue)
        }
    }

    /// `setup.started_at` / `setup.completed_at` as Unix milliseconds (0.9.5 `timestamp`).
    public var setupStartedAt: Int64? {
        get { timestamp(.setupStartedAt) }
        set { setTimestamp(newValue, .setupStartedAt) }
    }

    public var setupCompletedAt: Int64? {
        get { timestamp(.setupCompletedAt) }
        set { setTimestamp(newValue, .setupCompletedAt) }
    }

    private func timestamp(_ key: SettingsKey) -> Int64? {
        (defaults.object(forKey: key.rawValue) as? NSNumber)?.int64Value
    }

    private func setTimestamp(_ value: Int64?, _ key: SettingsKey) {
        if let value { defaults.set(NSNumber(value: value), forKey: key.rawValue) } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
