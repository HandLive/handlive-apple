#if os(iOS)
import Foundation
import HLAppCore
import HLProtocol
import UIKit
import UniformTypeIdentifiers

/// `UIPasteboard.general` for the clipboard engine (CLIP-04): only `changeCount` and the `has…` hints are read — never
/// the content, so iOS never asks "Allow Paste"; clips from the phone are written on this device only (`.localOnly`)
/// and expire after `clip.auto_clear_s` (CLIP-05).
@MainActor
public final class IOSPasteboard: ClipboardAccess {
    private let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public var changeCount: Int { UIPasteboard.general.changeCount }

    /// The suggestion banner says "a new image" when the clipboard holds one (CLIP-04 field 3).
    public var hasImages: Bool { UIPasteboard.general.hasImages }

    public func firstItemTypes() -> [String]? { nil }
    public func string(forType type: String) -> String? { nil }
    public func data(forType type: String) -> Data? { nil }

    /// API 1: `setItems(_:options:)` with `.localOnly` and `.expirationDate` when auto-clear is on; the clip carries
    /// `app.handlive.clip-id` so HandLive recognizes its own write.
    public func write(_ content: ClipContent, clipId: String, sensitive: Bool) -> Int? {
        var item: [String: Any] = [PasteboardTypeID.clipId: Data(clipId.utf8)]
        switch content {
        case .text(let text): item[UTType.utf8PlainText.identifier] = text
        case .image(let image):
            item[image.mime == ClipMime.png ? UTType.png.identifier : UTType.jpeg.identifier] = image.data
        }
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        let clearAfter = settings.autoClearSeconds
        if clearAfter > 0 { options[.expirationDate] = Date().addingTimeInterval(TimeInterval(clearAfter)) }
        UIPasteboard.general.setItems([item], options: options)
        return UIPasteboard.general.changeCount
    }

    public func clear() -> Int {
        UIPasteboard.general.setItems([], options: [.localOnly: true])
        return UIPasteboard.general.changeCount
    }
}
#endif
