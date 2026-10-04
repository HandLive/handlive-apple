import Foundation
import HLProtocol
@testable import HLAppCore

/// An in-memory pasteboard: one item with typed values, a `changeCount`, and counters of content reads.
@MainActor
final class FakePasteboard: ClipboardAccess {
    private(set) var changeCount = 1
    private(set) var types: [String] = []
    private var values: [String: Data] = [:]
    private(set) var contentReads = 0
    struct Write: Equatable {
        let content: ClipContent
        let clipId: String
        let sensitive: Bool
        var html: String?
    }

    private(set) var writes: [Write] = []
    var failWrites = false

    /// The user copies in another app.
    func copy(_ items: [(String, Data)]) {
        types = items.map(\.0)
        values = Dictionary(uniqueKeysWithValues: items)
        changeCount += 1
    }

    func copy(text: String, html: String, extraTypes: [String] = []) {
        copy([(PasteboardTypeID.text, Data(text.utf8)), (PasteboardTypeID.html, Data(html.utf8))]
            + extraTypes.map { ($0, Data()) })
    }

    func copy(text: String, extraTypes: [String] = []) {
        copy([(PasteboardTypeID.text, Data(text.utf8))] + extraTypes.map { ($0, Data()) })
    }

    func firstItemTypes() -> [String]? {
        contentReads += 1
        return types.isEmpty ? nil : types
    }

    func string(forType type: String) -> String? {
        contentReads += 1
        return values[type].flatMap { String(data: $0, encoding: .utf8) }
    }

    func data(forType type: String) -> Data? {
        contentReads += 1
        return values[type]
    }

    func write(_ content: ClipContent, clipId: String, sensitive: Bool) -> Int? {
        write(content, html: nil, clipId: clipId, sensitive: sensitive)
    }

    func write(_ content: ClipContent, html: String?, clipId: String, sensitive: Bool) -> Int? {
        guard !failWrites else { return nil }
        writes.append(Write(content: content, clipId: clipId, sensitive: sensitive, html: html))
        var items: [(String, Data)]
        switch content {
        case .text(let text):
            items = [(PasteboardTypeID.text, Data(text.utf8))]
            if let html { items.append((PasteboardTypeID.html, Data(html.utf8))) }
        case .image(let image): items = [(image.mime == ClipMime.png ? PasteboardTypeID.png : PasteboardTypeID.jpeg,
                                          image.data)]
        }
        items.append((PasteboardTypeID.clipId, Data(clipId.utf8)))
        if sensitive { items.append((PasteboardTypeID.concealed, Data())) }
        copy(items)
        return changeCount
    }

    func clear() -> Int {
        types = []
        values = [:]
        changeCount += 1
        return changeCount
    }
}
