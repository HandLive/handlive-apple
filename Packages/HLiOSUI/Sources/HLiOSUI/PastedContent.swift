import Foundation
import HLAppCore
import HLProtocol
import UniformTypeIdentifiers

/// What the system Paste button hands over (CLIP-04 step 9): text or a URL as UTF-8 text; an image as PNG or JPEG kept
/// as is, any other image type (HEIC…) converted to PNG. A text that also comes as HTML keeps its sanitized HTML form
/// (CLIP-04 API 3). `nil`: nothing that can be sent (E3, E7).
enum PastedContent {
    struct Loaded: Equatable {
        let content: ClipContent
        var html: String?
    }

    @MainActor
    static func load(_ providers: [NSItemProvider], imagesAllowed: Bool) async -> Loaded? {
        guard let provider = providers.first else { return nil }
        for type in [UTType.utf8PlainText, .plainText, .text] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(provider, type), let text = String(data: data, encoding: .utf8) {
                return Loaded(content: .text(text), html: await html(provider))
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let data = await data(provider, .url), let url = URL(dataRepresentation: data, relativeTo: nil) {
            return Loaded(content: .text(url.absoluteString))
        }
        guard imagesAllowed else { return nil }
        for type in [UTType.png, .jpeg, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            guard let data = await data(provider, type) else { continue }
            let identifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: type) ?? false
            } ?? type.identifier
            return ImageNormalizer.normalize(data, typeIdentifier: identifier).map { Loaded(content: .image($0)) }
        }
        return nil
    }

    /// The sanitized `public.html` representation when the provider offers one and something is left of it.
    @MainActor
    private static func html(_ provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.html.identifier),
              let data = await data(provider, .html), let raw = String(data: data, encoding: .utf8) else { return nil }
        let html = HtmlClipSanitizer.sanitize(raw)
        return html.isEmpty ? nil : html
    }

    @MainActor
    private static func data(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
