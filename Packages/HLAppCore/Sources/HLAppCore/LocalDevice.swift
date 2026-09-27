import Foundation
import HLProtocol

/// What this device tells the phone about itself (capability 0.7.2, `pair/hello`).
public struct LocalDevice: Sendable, Equatable {
    /// `"<marketing> (<build>)"`, e.g. `"1.0.0 (100)"`.
    public let appVersion: String
    public let osVersion: String
    /// `hw.model` (Mac) or the device identifier (iPhone).
    public let model: String
    /// Name shown to the phone at pairing (PAIR-01 field 3), at most 64 characters.
    public let name: String
    public let platform: CapabilityData.Platform

    public init(appVersion: String, osVersion: String, model: String, name: String, platform: CapabilityData.Platform) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.model = model
        self.name = String(name.prefix(64))
        self.platform = platform
    }

    /// Values of the running process.
    public static func current(name: String, platform: CapabilityData.Platform) -> LocalDevice {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)"
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let model = platform == .ios || platform == .ipados ? machineIdentifier() : hardwareModel()
        return LocalDevice(appVersion: "\(version) (\(build))", osVersion: osVersion, model: model,
                           name: name, platform: platform)
    }

    /// `uname` machine, e.g. `iPhone15,2` (`hw.model` names the board on iPhone and iPad).
    static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }

    /// `sysctl hw.model`, e.g. `Mac15,3`.
    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }

    /// Capability of this device (0.7.2) from its settings: what the app implements — clipboard, SMS and the relay
    /// switch; absent features count as off, so the phone sends nothing else. iPhone and iPad add `sms.notify`, which
    /// decides whether the phone pushes new messages (SET-02 field 8).
    public func capability(settings: AppSettings) -> CapabilityData {
        let mimes = settings.sendImages ? ClipboardLimits.mimes : [ClipboardLimits.textMime]
        let clipboard = ClipboardFeature(enabled: settings.clipboardEnabled, autoSend: true,
                                         maxTextBytes: ClipboardLimits.maxTextBytes,
                                         maxImageBytes: ClipboardLimits.maxImageBytes, mimes: mimes)
        let mobile = platform == .ios || platform == .ipados
        let sms = SmsFeature(enabled: settings.smsEnabled, notify: mobile ? settings.smsNotify : nil)
        return CapabilityData(appVersion: appVersion, platform: platform, osVersion: osVersion, model: model,
                              features: Features(clipboard: clipboard, sms: sms,
                                                 relay: RelayFeature(enabled: settings.relayEnabled)))
    }
}

/// `CLIP_MAX_TEXT`, `CLIP_MAX_IMAGE` (0.10) and the MIME types of `clipboard/push`.
public enum ClipboardLimits {
    public static let maxTextBytes: Int64 = 1_048_576
    public static let maxImageBytes: Int64 = 10_485_760
    public static let textMime = "text/plain"
    public static let pngMime = "image/png"
    public static let jpegMime = "image/jpeg"
    public static let mimes = [textMime, pngMime, jpegMime]
}
