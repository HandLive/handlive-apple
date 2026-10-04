import Foundation
import HLProtocol
import UniformTypeIdentifiers

/// What the user copied, as the first clipboard item shows it (CLIP-02 API 1 logic 3, CLIP-03 API 2).
enum LocalClip: Equatable {
    /// The item carries `app.handlive.clip-id`: HandLive wrote it (E1).
    case ownWrite(clipId: String?)
    /// Empty (an empty text too), a copied file that is not an image, or a type HandLive does not send (E3).
    case unsupported
/// `html` is the sanitized `public.html` of the same item, when it declares one.
    case text(String, html: String?, sensitiveType: Bool)
    /// Image bytes and their type identifier; normalized later, off the main actor.
    case image(Data, typeIdentifier: String, sensitiveType: Bool)
    /// An image file copied in Finder and the type its extension names; read and normalized later, off the main actor.
    case imageFile(URL, typeIdentifier: String, sensitiveType: Bool)
}

/// An image file copied in Finder, as read off the main actor (CLIP-03 API 2 logic 5).
enum ImageFileContent: Equatable, Sendable {
    case data(Data)
    /// Larger than `CLIP_MAX_IMAGE`: not read (E2).
    case tooLarge
    /// macOS refused access to its folder, or the file is gone (E3).
    case unreadable
}

@MainActor
enum LocalClipReader {
    /// Picks the kind from the first type of the first item that is text or an image, in the source app's order of
    /// preference. An item with a file URL is a copied file: an image file is the copied image, any other file skips
    /// the item whole (the file name is never sent). An empty text is nothing copied.
    static func read(_ access: ClipboardAccess) -> LocalClip {
        guard let types = access.firstItemTypes(), !types.isEmpty else { return .unsupported }
        if types.contains(PasteboardTypeID.clipId) {
            return .ownWrite(clipId: access.string(forType: PasteboardTypeID.clipId))
        }
        let sensitive = !SensitiveContent.pasteboardTypes.isDisjoint(with: types)
        if types.contains(PasteboardTypeID.fileURL) {
            guard let (url, identifier) = imageFile(access) else { return .unsupported }
            return .imageFile(url, typeIdentifier: identifier, sensitiveType: sensitive)
        }
        for type in types {
            if isText(type) {
                guard let text = access.string(forType: PasteboardTypeID.text), !text.isEmpty else { return .unsupported }
                return .text(text, html: sanitizedHtml(access, types: types), sensitiveType: sensitive)
            }
            if isImage(type) {
                guard let (data, identifier) = readImage(access, types: types) else { return .unsupported }
                return .image(data, typeIdentifier: identifier, sensitiveType: sensitive)
            }
        }
        return .unsupported
    }

    /// `public.html` of the first item when it declares one (CLIP-02 API 1): sanitized, `nil` when nothing is left.
    private static func sanitizedHtml(_ access: ClipboardAccess, types: [String]) -> String? {
        guard types.contains(PasteboardTypeID.html), let raw = access.string(forType: PasteboardTypeID.html) else {
            return nil
        }
        let html = HtmlClipSanitizer.sanitize(raw)
        return html.isEmpty ? nil : html
    }

    static func isText(_ type: String) -> Bool {
        type == PasteboardTypeID.text || (UTType(type)?.conforms(to: .plainText) ?? false)
    }

    static func isImage(_ type: String) -> Bool {
        UTType(type)?.conforms(to: .image) ?? false
    }

    /// The copied file and its type when its extension names an image type.
    private static func imageFile(_ access: ClipboardAccess) -> (URL, String)? {
        guard let string = access.string(forType: PasteboardTypeID.fileURL), let url = URL(string: string),
              url.isFileURL, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image)
        else { return nil }
        return (url, type.identifier)
    }

    /// Reads an image file copied in Finder; only a file within `CLIP_MAX_IMAGE`. The first read of a file on the
    /// Desktop or in Documents or Downloads may make macOS ask for access to that folder.
    nonisolated static func readImageFile(_ url: URL) -> ImageFileContent {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return .unreadable }
        guard size <= ClipboardConstants.maxImageBytes else { return .tooLarge }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .data(data)
    }

    /// `public.png` → `public.jpeg` → `public.tiff` → any other image type of the item (API 2 request order).
    private static func readImage(_ access: ClipboardAccess, types: [String]) -> (Data, String)? {
        let preferred = [PasteboardTypeID.png, PasteboardTypeID.jpeg, PasteboardTypeID.tiff]
        let candidates = preferred.filter(types.contains) + types.filter { isImage($0) && !preferred.contains($0) }
        for type in candidates {
            if let data = access.data(forType: type) { return (data, type) }
        }
        return nil
    }
}

/// A local change the phone has not acknowledged yet (QC8).
struct LocalChange: Equatable {
    let detectedAt: Date
    let originTs: Int64
    let originDeviceId: String
}

/// QC8 for an incoming `clipboard/push`.
enum ConflictDecision: Equatable {
    case write
    /// (a) The local change is younger than 500 ms: keep it, answer `ignored`/`conflict`, send `clipboard/conflict`.
    case keepLocalAndReport
    /// (b) Clips crossed each other and the local one wins (larger `origin_ts`, then larger `origin_device_id`).
    case keepLocal
}

enum ConflictPolicy {
    static func decide(originTs: Int64, originDeviceId: String, local: LocalChange?, now: Date) -> ConflictDecision {
        guard let local else { return .write }
        if now.timeIntervalSince(local.detectedAt) < ClipboardConstants.conflictWindow { return .keepLocalAndReport }
        if originTs != local.originTs { return originTs > local.originTs ? .write : .keepLocal }
        return originDeviceId > local.originDeviceId ? .write : .keepLocal
    }
}
