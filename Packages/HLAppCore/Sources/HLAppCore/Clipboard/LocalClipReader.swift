import Foundation
import UniformTypeIdentifiers

/// What the user copied, as the first clipboard item shows it (CLIP-02 API 1 logic 3, CLIP-03 API 2).
enum LocalClip: Equatable {
    /// The item carries `app.handlive.clip-id`: HandLive wrote it (E1).
    case ownWrite(clipId: String?)
    /// Empty, a copied file (`public.file-url`) or a type HandLive does not send (E3).
    case unsupported
    case text(String, sensitiveType: Bool)
    /// Image bytes and their type identifier; normalized later, off the main actor.
    case image(Data, typeIdentifier: String, sensitiveType: Bool)
}

@MainActor
enum LocalClipReader {
    /// Picks the kind from the first type of the first item that is text or an image, in the source app's order of
    /// preference; an item with a file URL is skipped whole (the file name is never sent).
    static func read(_ access: ClipboardAccess) -> LocalClip {
        guard let types = access.firstItemTypes(), !types.isEmpty else { return .unsupported }
        if types.contains(PasteboardTypeID.clipId) {
            return .ownWrite(clipId: access.string(forType: PasteboardTypeID.clipId))
        }
        if types.contains(PasteboardTypeID.fileURL) { return .unsupported }
        let sensitive = !SensitiveContent.pasteboardTypes.isDisjoint(with: types)
        for type in types {
            if isText(type) {
                guard let text = access.string(forType: PasteboardTypeID.text) else { return .unsupported }
                return .text(text, sensitiveType: sensitive)
            }
            if isImage(type) {
                guard let (data, identifier) = readImage(access, types: types) else { return .unsupported }
                return .image(data, typeIdentifier: identifier, sensitiveType: sensitive)
            }
        }
        return .unsupported
    }

    static func isText(_ type: String) -> Bool {
        type == PasteboardTypeID.text || (UTType(type)?.conforms(to: .plainText) ?? false)
    }

    static func isImage(_ type: String) -> Bool {
        UTType(type)?.conforms(to: .image) ?? false
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
