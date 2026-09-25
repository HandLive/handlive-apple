// `data` of the `clipboard` ops (CLIP-01 API 5–6, CLIP-03 API 3–5). The binary `chunk` plaintext is
// `ClipboardChunkPlaintext`.

/// `op` names of `type = clipboard` (0.7.1).
public enum ClipboardOp: String, Sendable {
    case push, chunk, cancel, conflict
}

/// MIME types a clip travels as (CLIP-01 API 5): text is always UTF-8.
public enum ClipMime {
    public static let text = "text/plain"
    public static let png = "image/png"
    public static let jpeg = "image/jpeg"
}

/// `transfer` of a chunked clip (CLIP-03 API 3): `sha256` is b64u of 32 bytes.
public struct ClipboardTransfer: Codable, Equatable, Sendable {
    public let transferId: String
    public let size: Int64
    public let sha256: String
    public let chunkSize: Int32
    public let chunkCount: Int32

    public init(transferId: String, size: Int64, sha256: String, chunkSize: Int32, chunkCount: Int32) {
        self.transferId = transferId
        self.size = size
        self.sha256 = sha256
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
    }

    enum CodingKeys: String, CodingKey {
        case size, sha256
        case transferId = "transfer_id"
        case chunkSize = "chunk_size"
        case chunkCount = "chunk_count"
    }
}

/// `clipboard/push` (CLIP-01 API 5, CLIP-03 API 3): exactly one of `text` (inline) and `transfer` (chunks);
/// `width`/`height` only for images; `origin_ts` is on the origin device's clock (QC8 b).
public struct ClipboardPushData: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, image
    }

    public enum Source: String, Codable, Sendable, LenientStringEnum {
        case auto, manual, share, mac, ios
        case unrecognized = ""
    }

    public let clipId: String
    public let kind: Kind
    public let mime: String
    public let text: String?
    public let transfer: ClipboardTransfer?
    public let width: Int32?
    public let height: Int32?
    public let sensitive: Bool
    public let originTs: Int64
    public let source: Source
    public let originDeviceId: String

    public init(clipId: String, kind: Kind, mime: String, text: String? = nil, transfer: ClipboardTransfer? = nil,
                width: Int32? = nil, height: Int32? = nil, sensitive: Bool, originTs: Int64, source: Source,
                originDeviceId: String) {
        self.clipId = clipId
        self.kind = kind
        self.mime = mime
        self.text = text
        self.transfer = transfer
        self.width = width
        self.height = height
        self.sensitive = sensitive
        self.originTs = originTs
        self.source = source
        self.originDeviceId = originDeviceId
    }

    enum CodingKeys: String, CodingKey {
        case kind, mime, text, transfer, width, height, sensitive, source
        case clipId = "clip_id"
        case originTs = "origin_ts"
        case originDeviceId = "origin_device_id"
    }
}

/// `ack.data` of a push (`applied`, `ignored` with a reason) and `ack.error.details` of a refused one (`rejected`,
/// with `transfer_id` for `CLIP_CHECKSUM_MISMATCH`).
public struct ClipboardAckData: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, LenientStringEnum {
        case applied, ignored, rejected
        case unrecognized = ""
    }

    public enum Reason: String, Codable, Sendable, LenientStringEnum {
        case conflict, duplicate, cancelled
        case unrecognized = ""
    }

    public let clipId: String
    public let status: Status
    public let reason: Reason?
    public let transferId: String?

    public init(clipId: String, status: Status, reason: Reason? = nil, transferId: String? = nil) {
        self.clipId = clipId
        self.status = status
        self.reason = reason
        self.transferId = transferId
    }

    enum CodingKeys: String, CodingKey {
        case status, reason
        case clipId = "clip_id"
        case transferId = "transfer_id"
    }
}

/// `clipboard/cancel` (CLIP-03 API 5).
public struct ClipboardCancelData: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable, LenientStringEnum {
        case superseded, user, timeout
        case unrecognized = ""
    }

    public let transferId: String
    public let reason: Reason

    public init(transferId: String, reason: Reason) {
        self.transferId = transferId
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case transferId = "transfer_id"
    }
}

/// `clipboard/conflict` (CLIP-01 API 6): the device that kept its own content, for "Send Again".
public struct ClipboardConflictData: Codable, Equatable, Sendable {
    public let clipId: String
    public let originDeviceId: String
    public let deviceId: String
    public let deviceName: String

    public init(clipId: String, originDeviceId: String, deviceId: String, deviceName: String) {
        self.clipId = clipId
        self.originDeviceId = originDeviceId
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id"
        case originDeviceId = "origin_device_id"
        case deviceId = "device_id"
        case deviceName = "device_name"
    }
}
