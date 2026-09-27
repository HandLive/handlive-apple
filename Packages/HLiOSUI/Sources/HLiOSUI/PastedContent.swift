import Foundation
import HLAppCore
import UniformTypeIdentifiers

/// What the system Paste button hands over (CLIP-04 step 9): text or a URL as UTF-8 text; an image as PNG or JPEG kept
/// as is, any other image type (HEIC…) converted to PNG. `nil`: nothing that can be sent (E3, E7).
enum PastedContent {
    @MainActor
    static func load(_ providers: [NSItemProvider], imagesAllowed: Bool) async -> ClipContent? {
        guard let provider = providers.first else { return nil }
        for type in [UTType.utf8PlainText, .plainText, .text] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(provider, type), let text = String(data: data, encoding: .utf8) { return .text(text) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let data = await data(provider, .url), let url = URL(dataRepresentation: data, relativeTo: nil) {
            return .text(url.absoluteString)
        }
        guard imagesAllowed else { return nil }
        for type in [UTType.png, .jpeg, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            guard let data = await data(provider, type) else { continue }
            let identifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: type) ?? false
            } ?? type.identifier
            return ImageNormalizer.normalize(data, typeIdentifier: identifier).map { .image($0) }
        }
        return nil
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
