import AppKit
import Foundation
import HLLocalization
import Testing
@testable import HLMacUI

@Suite("App coordinator: Dock menu and window keys")
@MainActor
struct AppCoordinatorTests {
    @Test("Dock menu: Add Phone… while unpaired; New Message and Send Clipboard to Phone dimmed while unusable")
    func dockMenu() throws {
        let coordinator = AppCoordinator(model: makeModel())
        coordinator.model.launch()
        var sent = false
        coordinator.sendClipboard = { sent = true }
        let menu = coordinator.dockMenu()
        #expect(menu.items.map(\.title) == [L10n.Pairing.addPhone, L10n.Sms.newMessage, L10n.Menu.sendClipboardToPhone])
        #expect(menu.items[0].isEnabled && !menu.items[1].isEnabled && !menu.items[2].isEnabled)
        // A dimmed item does not fire from the menu; its action still reaches the clipboard module.
        let item = menu.items[2]
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        #expect(sent)
        try coordinator.model.completePairing(PairingControllerTests.result())
        let paired = coordinator.dockMenu()
        #expect(paired.items.map(\.title) == [L10n.Sms.newMessage, L10n.Menu.sendClipboardToPhone])
        #expect(paired.items[0].isEnabled)
    }

    @Test("The menu bar count of unread conversations: none, the number, 99+ above 99")
    func unreadBadge() {
        let model = makeModel()
        #expect(model.unreadBadgeText == nil)
        model.handleSmsEvent(.badge(2))
        #expect(model.unreadBadgeText == "2")
        model.handleSmsEvent(.badge(120))
        #expect(model.unreadBadgeText == "99+")
    }

    @Test("⌘W and Esc close the welcome and Settings windows in accessory mode; other keys pass")
    func windowKeys() {
        #expect(WindowKeyMonitor.closes(keyCode: 13, modifiers: .command, characters: "w"))
        #expect(WindowKeyMonitor.closes(keyCode: 13, modifiers: [.command, .capsLock], characters: "W"))
        #expect(WindowKeyMonitor.closes(keyCode: 53, modifiers: [], characters: "\u{1b}"))
        #expect(!WindowKeyMonitor.closes(keyCode: 53, modifiers: .option, characters: "\u{1b}"))
        #expect(!WindowKeyMonitor.closes(keyCode: 13, modifiers: [.command, .shift], characters: "w"))
        #expect(!WindowKeyMonitor.closes(keyCode: 12, modifiers: .command, characters: "q"))
    }

    @Test("The privacy page follows the display language, as on Android")
    func privacyPage() {
        #expect(PrivacyPage.url(displayLanguage: "vi")?.absoluteString
            == "https://github.com/HandLive/handlive/blob/main/docs/privacy.vi.md")
        #expect(PrivacyPage.url(displayLanguage: "en")?.absoluteString
            == "https://github.com/HandLive/handlive/blob/main/docs/privacy.md")
        #expect(PrivacyPage.url(displayLanguage: nil) == PrivacyPage.english)
    }
}
