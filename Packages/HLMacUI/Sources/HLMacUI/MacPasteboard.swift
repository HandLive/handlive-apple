import AppKit
import HLAppCore
import HLProtocol

/// `NSPasteboard.general` for the clipboard engine (CLIP-02 API 1, CLIP-01 API 7, CLIP-03 API 7, CLIP-05 API 1).
@MainActor
final class MacPasteboard: ClipboardAccess {
    private let pasteboard = NSPasteboard.general
    /// Keeps the PNG promise of a JPEG alive while it is on the clipboard.
    private var provider: PNGPromise?

    var changeCount: Int { pasteboard.changeCount }

    func firstItemTypes() -> [String]? {
        pasteboard.pasteboardItems?.first?.types.map(\.rawValue)
    }

    func string(forType type: String) -> String? {
        pasteboard.pasteboardItems?.first?.string(forType: NSPasteboard.PasteboardType(type))
    }

    func data(forType type: String) -> Data? {
        pasteboard.pasteboardItems?.first?.data(forType: NSPasteboard.PasteboardType(type))
    }

    /// One item with every type, written in one pass, kept on this Mac (`.currentHostOnly`: no Universal Clipboard);
    /// `changeCount` is read only afterwards (API 7 logic 1–2). A JPEG also promises PNG, made only when an app asks.
    func write(_ content: ClipContent, clipId: String, sensitive: Bool) -> Int? {
        let item = NSPasteboardItem()
        var written = true
        provider = nil
        switch content {
        case .text(let text):
            written = item.setString(text, forType: .string)
        case .image(let image) where image.mime == ClipMime.jpeg:
            written = item.setData(image.data, forType: NSPasteboard.PasteboardType(PasteboardTypeID.jpeg))
            let promise = PNGPromise(jpeg: image.data)
            written = written && item.setDataProvider(promise, forTypes: [.png])
            provider = promise
        case .image(let image):
            written = item.setData(image.data, forType: .png)
        }
        written = written && item.setString(clipId, forType: NSPasteboard.PasteboardType(PasteboardTypeID.clipId))
        if sensitive {
            written = written && item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardTypeID.concealed))
        }
        guard written else { return nil }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects([item]) else { return nil }
        return pasteboard.changeCount
    }

    func clear() -> Int {
        provider = nil
        return pasteboard.clearContents()
    }
}

/// Converts a received JPEG to PNG when another app pastes and asks for PNG (many Mac apps read only PNG or TIFF).
private final class PNGPromise: NSObject, NSPasteboardItemDataProvider {
    private let jpeg: Data

    init(jpeg: Data) {
        self.jpeg = jpeg
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .png, let png = ImageNormalizer.png(fromJPEG: jpeg) else { return }
        item.setData(png, forType: .png)
    }
}
