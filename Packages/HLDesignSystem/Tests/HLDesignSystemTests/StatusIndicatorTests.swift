import Foundation
import HLLocalization
import Testing
@testable import HLDesignSystem

@Suite("StatusIndicator")
struct StatusIndicatorTests {
    @Test("Text comes from the status.* strings of the catalog (0.11, PAIR-02)")
    func textsComeFromCatalog() {
        #expect(HLConnectionStatus.connectedWiFi.text == L10n.Status.connectedWifi)
        #expect(HLConnectionStatus.connectedWiFi.shortText == L10n.Status.channelLan)
        #expect(HLConnectionStatus.connectedInternet.text == L10n.Status.connectedInternet)
        #expect(HLConnectionStatus.usb.text == L10n.Status.connectedUsb)
        #expect(HLConnectionStatus.connecting.text == L10n.Status.connecting)
        #expect(HLConnectionStatus.phoneOffline(lastSeen: "14:05").text == L10n.Status.peerOfflineSince(time: "14:05"))
        #expect(HLConnectionStatus.phoneOffline(lastSeen: nil).text == L10n.Status.peerOffline)
        #expect(HLConnectionStatus.networkLost.text == L10n.Status.disconnected)
        #expect(HLConnectionStatus.needsRepair.text == L10n.Status.repairNeeded)
        #expect(HLConnectionStatus.notPaired.text == L10n.Status.notPaired)
    }

    @Test("English and Vietnamese texts match the README table")
    func bothLanguages() {
        #expect(L10nLookup.string("status.connected_wifi", localization: "en") == "Connected via Wi-Fi")
        #expect(L10nLookup.string("status.connected_wifi", localization: "vi") == "Đã kết nối qua Wi-Fi")
        #expect(L10nLookup.string("status.repair_needed", localization: "vi") == "Cần ghép nối lại")
    }

    @Test("VoiceOver reads the full sentence with the device name")
    func accessibilityTextIncludesDevice() {
        #expect(HLConnectionStatus.connectedWiFi.accessibilityText(deviceName: "Pixel 8")
            == L10n.Status.connectedWifiTo(deviceName: "Pixel 8"))
        #expect(HLConnectionStatus.networkLost.accessibilityText(deviceName: "Pixel 8") == L10n.Status.disconnected)
        #expect(HLConnectionStatus.connectedWiFi.accessibilityText(deviceName: nil) == L10n.Status.connectedWifi)
    }

    @Test("Offline is gray, red only when the user must act; only connecting pulses")
    func colorsAndPulse() {
        #expect(HLConnectionStatus.phoneOffline(lastSeen: nil).colorToken == .statusOffline)
        #expect(HLConnectionStatus.networkLost.colorToken == .statusOffline)
        #expect(HLConnectionStatus.notPaired.colorToken == .statusOffline)
        #expect(HLConnectionStatus.needsRepair.colorToken == .statusError)
        #expect(HLConnectionStatus.connecting.colorToken == .statusConnecting)
        #expect(HLConnectionStatus.connecting.pulses)
        #expect(!HLConnectionStatus.connectedWiFi.pulses)
        let opacity = StatusIndicator.pulseOpacity(at: Date(timeIntervalSinceReferenceDate: 0))
        #expect(abs(opacity - 1) < 0.0001)
    }
}
