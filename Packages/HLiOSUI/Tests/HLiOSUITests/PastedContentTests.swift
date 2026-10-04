import Foundation
import HLAppCore
import Testing
import UniformTypeIdentifiers
@testable import HLiOSUI

/// CLIP-04 API 3: what the system Paste button hands over becomes a clip; a text that also comes as HTML keeps it.
@Suite("Pasted content with HTML (CLIP-04 API 3)")
@MainActor
struct PastedContentTests {
    private func provider(text: String, html: String?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) {
            $0(Data(text.utf8), nil)
            return nil
        }
        if let html {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) {
                $0(Data(html.utf8), nil)
                return nil
            }
        }
        return provider
    }

    @Test("A text offered with HTML loads both, the HTML sanitized")
    func textWithHtml() async throws {
        let loaded = await PastedContent.load(
            [provider(text: "Hi Lan", html: "<p onclick=\"x\">Hi <b>Lan</b></p><script>bad()</script>")],
            imagesAllowed: true)
        #expect(loaded == PastedContent.Loaded(content: .text("Hi Lan"), html: "<p>Hi <b>Lan</b></p>"))
    }

    @Test("A text without HTML, or whose HTML sanitizes to nothing, loads as text alone")
    func textWithoutHtml() async throws {
        let plain = await PastedContent.load([provider(text: "Hi", html: nil)], imagesAllowed: true)
        #expect(plain == PastedContent.Loaded(content: .text("Hi")))
        let empty = await PastedContent.load([provider(text: "Hi", html: "<script>bad()</script>")], imagesAllowed: true)
        #expect(empty == PastedContent.Loaded(content: .text("Hi")))
    }
}
