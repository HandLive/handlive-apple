import Foundation

/// Pasteboard type identifiers the clipboard feature reads and writes (CLIP-02 API 1, CLIP-01 API 7).
public enum PasteboardTypeID {
    public static let text = "public.utf8-plain-text"
    public static let png = "public.png"
    public static let jpeg = "public.jpeg"
    public static let tiff = "public.tiff"
    public static let fileURL = "public.file-url"
    /// Marks HandLive's own writes (QC4, CLIP-05).
    public static let clipId = "app.handlive.clip-id"
    /// Written with a sensitive clip so clipboard managers do not store it.
    public static let concealed = "org.nspasteboard.ConcealedType"
}

/// The system clipboard as the clipboard engine sees it: `NSPasteboard.general` on the Mac, a fake in tests.
@MainActor
public protocol ClipboardAccess: AnyObject {
    /// Changes on every write by any app; reading it reads no content (C10).
    var changeCount: Int { get }
    /// Types of the first item in the source app's order of preference; `nil` when the clipboard is empty.
    func firstItemTypes() -> [String]?
    func string(forType type: String) -> String?
    func data(forType type: String) -> Data?
    /// Replaces the clipboard with the clip, marked with `app.handlive.clip-id` (and concealed when sensitive), kept
    /// on this machine; returns `changeCount` after the write, or `nil` when the system refused it (`INTERNAL`).
    func write(_ content: ClipContent, clipId: String, sensitive: Bool) -> Int?
    /// Empties the clipboard; returns the new `changeCount` (CLIP-05 step 8).
    func clear() -> Int
}
