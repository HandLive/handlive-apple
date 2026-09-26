import Foundation
import Testing
@testable import HLDesignSystem

/// `MessageBubble/README.md`: links and phone numbers in a message are detected and underlined.
@Suite("MessageBubble")
struct MessageBubbleTests {
    @Test("A URL and a phone number become links; plain text stays plain")
    func links() {
        let attributed = MessageBubble.linked("Xem https://handlive.app hoặc gọi 0900 000 123 nhé")
        let links = attributed.runs.compactMap(\.link)
        #expect(links.contains { $0.absoluteString == "https://handlive.app" })
        #expect(links.contains { $0.scheme == "tel" })
        #expect(MessageBubble.linked("Chiều nay 3h họp nhé").runs.allSatisfy { $0.link == nil })
    }
}
