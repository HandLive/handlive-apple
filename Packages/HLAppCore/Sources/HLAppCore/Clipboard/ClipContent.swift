import Foundation
import HLCrypto
import HLProtocol
import ImageIO
import UniformTypeIdentifiers

/// A normalized clipboard image: PNG or JPEG bytes and their size in pixels (CLIP-03 step 4).
public struct ClipImage: Sendable, Equatable {
    public let data: Data
    public let mime: String
    public let width: Int32
    public let height: Int32

    public init(data: Data, mime: String, width: Int32, height: Int32) {
        self.data = data
        self.mime = mime
        self.width = width
        self.height = height
    }
}

/// What travels in a clip; it lives only in memory and in the temporary transfer files (QC2).
public enum ClipContent: Sendable, Equatable {
    case text(String)
    case image(ClipImage)

    /// UTF-8 of the text or the image bytes: what is hashed, measured and chunked.
    public var bytes: Data {
        switch self {
        case .text(let text): Data(text.utf8)
        case .image(let image): image.data
        }
    }

    public var kind: ClipboardPushData.Kind {
        switch self {
        case .text: .text
        case .image: .image
        }
    }

    public var mime: String {
        switch self {
        case .text: ClipMime.text
        case .image(let image): image.mime
        }
    }

    /// SHA-256 of `bytes` (QC4 and `transfer.sha256`).
    public var sha256: Data { HMACSHA256.sha256(bytes) }
}

/// PNG and JPEG keep their bytes; any other image ImageIO reads (TIFF, HEIC, GIF, WebP…) becomes PNG, first frame
/// only (CLIP-03 API 2). Runs off the main actor for large images.
public enum ImageNormalizer {
    /// `nil` when the data is not an image ImageIO can decode (E3).
    public static func normalize(_ data: Data, typeIdentifier: String) -> ClipImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let size = pixelSize(source)
        else { return nil }
        switch typeIdentifier {
        case UTType.png.identifier:
            return ClipImage(data: data, mime: ClipMime.png, width: size.width, height: size.height)
        case UTType.jpeg.identifier:
            return ClipImage(data: data, mime: ClipMime.jpeg, width: size.width, height: size.height)
        default:
            return convertToPNG(source)
        }
    }

    /// PNG of a JPEG, for the pasteboard's promised `.png` type (CLIP-03 API 7).
    public static func png(fromJPEG data: Data) -> Data? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(convertToPNG)?.data
    }

    private static func convertToPNG(_ source: CGImageSource) -> ClipImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ClipImage(data: output as Data, mime: ClipMime.png, width: Int32(image.width), height: Int32(image.height))
    }

    private static func pixelSize(_ source: CGImageSource) -> (width: Int32, height: Int32)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (Int32(width), Int32(height))
    }
}
