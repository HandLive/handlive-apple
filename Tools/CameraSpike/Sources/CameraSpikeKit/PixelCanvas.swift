/// A 32-bit BGRA pixel buffer (`kCVPixelFormatType_32BGRA`) seen as rows of `UInt32`. On a little-endian Mac the
/// bytes B, G, R, A of one pixel read as the value `A << 24 | R << 16 | G << 8 | B`.
public struct PixelCanvas {
    public let base: UnsafeMutableRawPointer
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        precondition(bytesPerRow >= width * 4, "a row must hold width BGRA pixels")
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    /// Opaque color from 8-bit components.
    public static func color(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        0xFF00_0000 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    public static let black = color(red: 0, green: 0, blue: 0)
    public static let white = color(red: 255, green: 255, blue: 255)

    /// Fills the rectangle at (`left`, `top`), clipped to the canvas.
    public func fill(left: Int, top: Int, width rectWidth: Int, height rectHeight: Int, color: UInt32) {
        let left0 = max(left, 0), top0 = max(top, 0)
        let right = min(left + rectWidth, width), bottom = min(top + rectHeight, height)
        guard left0 < right, top0 < bottom else { return }
        for row in top0..<bottom {
            let pixels = (base + row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            UnsafeMutableBufferPointer(start: pixels + left0, count: right - left0).update(repeating: color)
        }
    }

    public func fill(_ rect: PixelRect, color: UInt32) {
        fill(left: rect.left, top: rect.top, width: rect.width, height: rect.height, color: color)
    }

    /// Pixel in `column` of `row`; the caller keeps the point inside the canvas.
    public func pixel(column: Int, row: Int) -> UInt32 {
        (base + row * bytesPerRow).assumingMemoryBound(to: UInt32.self)[column]
    }

    /// Rec. 601 luma, 0…255, of a pixel.
    public func luma(column: Int, row: Int) -> Int {
        let value = pixel(column: column, row: row)
        let red = Int(value >> 16 & 0xFF), green = Int(value >> 8 & 0xFF), blue = Int(value & 0xFF)
        return (299 * red + 587 * green + 114 * blue) / 1000
    }
}

/// A rectangle in pixels, top-left origin.
public struct PixelRect: Sendable, Equatable {
    public var left, top, width, height: Int

    public init(_ left: Int, _ top: Int, _ width: Int, _ height: Int) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}
