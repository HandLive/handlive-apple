import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// "Open at login" through `SMAppService.mainApp` (SET-03 API 3, SET-02 field 22); the real state is always read
/// from `status`, never kept in a setting.
public enum LoginItem {
    public enum Status: Equatable, Sendable {
        case enabled, requiresApproval, notRegistered, notFound
    }

    public static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    /// Registers or unregisters; returns the status afterwards (E5 when approval is required or MDM blocks it).
    @discardableResult
    public static func set(_ enabled: Bool) -> Status {
        if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        return status
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// "Paste from Other Apps" on macOS 15.4+ (C10, SET-03 API 6).
public enum PasteAccess: Equatable, Sendable {
    case notApplicable, standard, ask, alwaysAllow, alwaysDeny

    public static var current: PasteAccess {
        guard #available(macOS 15.4, *) else { return .notApplicable }
        switch NSPasteboard.general.accessBehavior {
        case .ask: return .ask
        case .alwaysAllow: return .alwaysAllow
        case .alwaysDeny: return .alwaysDeny
        default: return .standard
        }
    }

    /// The Mac asks or refuses: show the guide and never read the clipboard on a timer (CLIP-02 E2).
    public var needsGuide: Bool { self == .ask || self == .alwaysDeny }
    /// Reading on the 500 ms poll is allowed (`.ask` still lets the menu command read, with the system prompt).
    public var allowsPolling: Bool { self != .ask && self != .alwaysDeny }
}

/// Pages of System Settings the guides open (SET-03 field 13).
public enum SystemSettingsPane {
    case privacyAndSecurity, localNetwork, notifications, loginItems

    public func open() {
        if self == .loginItems { return LoginItem.openSystemSettings() }
        let address = switch self {
        case .privacyAndSecurity: "x-apple.systempreferences:com.apple.preference.security"
        case .localNetwork: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .loginItems: ""
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

/// Where the app runs from (SET-03 field 4): the virtual camera needs /Applications (C11).
public enum ApplicationLocation: Equatable, Sendable {
    case applications, other, translocated

    public static func of(_ bundleURL: URL) -> ApplicationLocation {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .translocated }
        return path.hasPrefix("/Applications/") ? .applications : .other
    }

    public static var current: ApplicationLocation { of(Bundle.main.bundleURL) }

    /// Copies the bundle to /Applications, opens the copy and quits (SET-03 API 2). Returns `false` when the copy is
    /// not possible (translocated, no write access, a different app already there): show the drag hint (E2).
    @MainActor
    public static func moveToApplications() -> Bool {
        let source = Bundle.main.bundleURL
        guard of(source) == .other else { return false }
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.copyItem(at: source, to: destination)) != nil
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--moved-from", source.path]
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
        return true
    }

    /// The copy in /Applications moves the old bundle to the Trash (SET-03 API 2 logic).
    public static func removeMovedFromCopy(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--moved-from"), arguments.indices.contains(index + 1) else { return }
        let old = URL(fileURLWithPath: arguments[index + 1])
        guard of(old) != .applications else { return }
        try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
    }
}

/// Notification permission (SET-03 API 4): asked once; afterwards only read.
public enum NotificationPermission: Equatable, Sendable {
    case notDetermined, allowed, denied

    public static func current() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    /// `requestAuthorization([.alert, .sound, .badge])`; no provisional, no critical alerts.
    public static func request() async -> NotificationPermission {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await current()
    }
}

/// Hardware facts `pair/hello` carries (PAIR-01 API 2 `model`).
public enum MacHardware {
    /// Model identifier such as `Mac15,3` (`hw.model`).
    public static var modelIdentifier: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
