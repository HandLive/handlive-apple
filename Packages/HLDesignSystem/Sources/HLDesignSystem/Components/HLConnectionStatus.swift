import Foundation
import HLLocalization

/// Link state between the two devices, per the table of `StatusIndicator/README.md`; text comes from the string
/// catalog (`status.*`, 0.11, PAIR-02 field 4).
public enum HLConnectionStatus: Hashable, Sendable {
    case connectedWiFi
    case connectedInternet
    case usb
    case connecting
    /// Phone offline; `lastSeen` is a time already formatted for the locale, for example "14:05".
    case phoneOffline(lastSeen: String?)
    case networkLost
    case needsRepair
    /// No phone paired yet (first run, after unpairing).
    case notPaired

    /// Full text.
    public var text: String {
        switch self {
        case .connectedWiFi: L10n.Status.connectedWifi
        case .connectedInternet: L10n.Status.connectedInternet
        case .usb: L10n.Status.connectedUsb
        case .connecting: L10n.Status.connecting
        case .phoneOffline(let lastSeen?): L10n.Status.peerOfflineSince(time: lastSeen)
        case .phoneOffline(nil): L10n.Status.peerOffline
        case .networkLost: L10n.Status.disconnected
        case .needsRepair: L10n.Status.repairNeeded
        case .notPaired: L10n.Status.notPaired
        }
    }

    /// Short label for the pill variant: only Wi-Fi has one ("LAN").
    public var shortText: String {
        self == .connectedWiFi ? L10n.Status.channelLan : text
    }

    /// Sentence VoiceOver reads: "Connected via Wi-Fi to Lan's Pixel 8".
    public func accessibilityText(deviceName: String?) -> String {
        guard let deviceName, !deviceName.isEmpty, self == .connectedWiFi else { return text }
        return L10n.Status.connectedWifiTo(deviceName: deviceName)
    }

    /// SF Symbol; `nil` when the state shows a pulsing dot.
    public var symbolName: String? {
        switch self {
        case .connectedWiFi: "wifi"
        case .connectedInternet: "globe"
        case .usb: "cable.connector"
        case .phoneOffline: "antenna.radiowaves.left.and.right.slash"
        case .networkLost: "wifi.slash"
        case .needsRepair: "exclamationmark.triangle.fill"
        case .notPaired: "iphone.slash"
        case .connecting: nil
        }
    }

    /// Shaped symbol replacing the dot when Differentiate Without Color is on (01-mau-sac.md).
    public var differentiateWithoutColorSymbolName: String {
        switch self {
        case .connecting: "ellipsis.circle.fill"
        default: symbolName ?? "circle.fill"
        }
    }

    /// Pulsing dot (still when Reduce Motion is on).
    public var pulses: Bool { self == .connecting }

    public var colorToken: HLColorToken {
        switch self {
        case .connectedWiFi, .connectedInternet, .usb: .statusConnected
        case .connecting: .statusConnecting
        case .phoneOffline, .networkLost, .notPaired: .statusOffline
        case .needsRepair: .statusError
        }
    }
}
