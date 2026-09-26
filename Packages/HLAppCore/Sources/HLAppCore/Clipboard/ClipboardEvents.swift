import Foundation
import HLProtocol

/// Results the clipboard reports in place: a status line in the menu bar menu, the checkmark on the icon after a
/// manual send (Feedback). Never a system notification (QC5, C19).
public enum ClipboardNotice: Equatable, Sendable {
    /// Manual send acknowledged: checkmark for about a second, "Sent to <name>".
    case sent(deviceName: String)
    /// Manual send while the phone is not connected (E6).
    case notConnectedWillSend
    /// Manual send with nothing to send.
    case emptyOrNotText
    /// Manual send of what just came from the phone (QC4).
    case skippedJustReceived(deviceName: String)
    case textTooLarge
    case imageTooLarge
    case imageUnreadable
    /// The phone could not write its clipboard (`INTERNAL`, CLIP-02 E8), or refused a manual send.
    case writeFailedOnPhone
    /// The image failed its SHA-256 check twice (CLIP-03 E4).
    case imageSendFailed
    /// No room for the temporary file of an incoming image (CLIP-03 E9).
    case imageNoSpace
    /// macOS asks or refuses paste access: automatic sending is off (C10, CLIP-02 E2), once per launch.
    case pasteAccessNeeded
    /// iPhone/iPad: no `ack` within 10 s; not replayed (CLIP-04 E9).
    case sendFailed
    /// iPhone/iPad: the pasted content is not text, a URL or a supported image (CLIP-04 E3).
    case unsupportedContent
}

/// System notifications with a button (QC3, CLIP-01 API 6); a new one replaces the old one of the same kind.
public enum ClipboardAlert: Equatable, Sendable {
    /// "Sensitive Content Blocked" with "Send Anyway".
    case sensitiveBlocked
    /// "Clipboard Not Updated on <device name>" with "Send Again".
    case conflict(deviceName: String)
}

/// Progress of a transfer larger than 1 MiB (CLIP-03 field 2), with "Cancel".
public struct ClipboardProgress: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case sending, receiving
    }

    public let direction: Direction
    public let transferId: String
    public let deviceName: String
    /// 0…1: chunks sent or received over `chunk_count`.
    public let fraction: Double

    public init(direction: Direction, transferId: String, deviceName: String, fraction: Double) {
        self.direction = direction
        self.transferId = transferId
        self.deviceName = deviceName
        self.fraction = fraction
    }
}

/// A clip copied on this device, the latest one kept for replay until the phone acknowledges it (QC7).
final class OutgoingClip {
    let clipId: String
    let content: ClipContent
    let sensitive: Bool
    let originTs: Int64
    let createdAt: Date
    let manual: Bool
    var acknowledged = false
    /// Sent again after a reconnection: a conflict for it is not shown (CLIP-01 API 6 logic 3).
    var replayed = false

    init(clipId: String, content: ClipContent, sensitive: Bool, originTs: Int64, createdAt: Date, manual: Bool) {
        self.clipId = clipId
        self.content = content
        self.sensitive = sensitive
        self.originTs = originTs
        self.createdAt = createdAt
        self.manual = manual
    }
}

/// The push being sent: its clip, the transfer once chunks start, and the task to cancel (superseded, user).
struct SendingState {
    let clipId: String
    var transferId: String?
    let task: Task<Void, Never>
}

/// HandLive's last write to the clipboard (QC4, CLIP-05): `changeCount` right after it, and when.
struct OwnWrite: Equatable {
    let changeCount: Int
    let clipId: String
    let writtenAt: Date
}

/// Content held for "Send Anyway" or "Send Again", at most `CLIP_STALE_AFTER`.
struct HeldClip {
    let content: ClipContent
    let sensitive: Bool
    let heldAt: Date
}
