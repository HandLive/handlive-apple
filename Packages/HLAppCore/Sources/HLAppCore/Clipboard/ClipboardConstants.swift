import Foundation

/// Constants of the clipboard group (0.10, 04-clipboard.md).
public enum ClipboardConstants {
    /// `CLIP_MAX_TEXT`: 1 MiB of UTF-8.
    public static let maxTextBytes = 1_048_576
    /// `CLIP_MAX_IMAGE`: 10 MiB after normalization.
    public static let maxImageBytes = 10_485_760
    /// `CLIP_INLINE_MAX`: a `clipboard/push` plaintext up to this size carries the text inline (QC5).
    public static let inlineMaxPlaintext = 180 * 1024
    /// `CHUNK_SIZE`, before encryption.
    public static let chunkSize = 65_536
    /// `CLIP_POLL_MAC`.
    public static let pollInterval: Duration = .milliseconds(500)
    /// `CLIP_CONFLICT_WINDOW`, on the receiver's clock (QC8 a).
    public static let conflictWindow: TimeInterval = 0.5
    /// `CLIP_LOOP_WINDOW` (QC4).
    public static let loopWindow: TimeInterval = 5
    /// `CLIP_STALE_AFTER`: replay (QC7), "Send Anyway" and "Send Again" (QC3, CLIP-01 API 6).
    public static let staleAfter: TimeInterval = 120
    /// `CLIP_TRANSFER_IDLE_TIMEOUT` (CLIP-03 E7).
    public static let transferIdleTimeout: Duration = .seconds(30)
    /// Progress is shown for images larger than this (CLIP-03 field 2).
    public static let progressThreshold = 1_048_576
    /// De-duplication by `clip_id`: the latest 256 for 10 minutes (QC6).
    public static let ledgerCapacity = 256
    public static let ledgerWindow: TimeInterval = 600
}
