import Foundation
import HLAppCore

/// The clipboard the dev client's `ClipboardEngine` reads and writes instead of `NSPasteboard.general`: a text copied
/// with `copy(_:)`, clips from the phone kept in memory.
@MainActor
final class MemoryPasteboard: ClipboardAccess {
    private(set) var changeCount = 0
    private(set) var content: ClipContent?

    /// "The user copied" a text: the next "Send Clipboard to Phone" sends it.
    func copy(_ text: String) {
        content = .text(text)
        changeCount += 1
    }

    func firstItemTypes() -> [String]? {
        switch content {
        case .text?: [PasteboardTypeID.text]
        case .image?: [PasteboardTypeID.png]
        case nil: nil
        }
    }

    func string(forType type: String) -> String? {
        guard type == PasteboardTypeID.text, case .text(let text)? = content else { return nil }
        return text
    }

    func data(forType type: String) -> Data? {
        guard case .image(let image)? = content else { return nil }
        return image.data
    }

    func write(_ content: ClipContent, clipId: String, sensitive: Bool) -> Int? {
        self.content = content
        changeCount += 1
        return changeCount
    }

    func clear() -> Int {
        content = nil
        changeCount += 1
        return changeCount
    }
}
