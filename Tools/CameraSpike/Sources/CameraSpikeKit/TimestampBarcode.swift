/// A machine-readable timestamp across the top of each frame: 64 black/white cells over the full width, the 32 bits
/// of a millisecond host-clock value (most significant first) followed by their 32 inverted bits as a check. The host's
/// self-check reads it back from the virtual camera to measure latency without a human; cells are sampled at their
/// centres relative to the frame size, so a consumer that scales the frame can still read it.
public enum TimestampBarcode {
    public static let cellCount = 64
    /// Height of the strip as a fraction of the frame height (48 px at 720p).
    public static let heightFraction = 48.0 / 720.0

    public static func stripHeight(frameHeight: Int) -> Int {
        max(Int((Double(frameHeight) * heightFraction).rounded()), 8)
    }

    /// The 64 cells for `value`: `true` is white.
    public static func cells(for value: UInt32) -> [Bool] {
        let bits = (0..<32).map { value >> (31 - UInt32($0)) & 1 == 1 }
        return bits + bits.map { !$0 }
    }

    /// Draws the strip for `value` at the top of `canvas`.
    public static func draw(_ value: UInt32, on canvas: PixelCanvas) {
        let height = stripHeight(frameHeight: canvas.height)
        for (index, isWhite) in cells(for: value).enumerated() {
            let left = index * canvas.width / cellCount, right = (index + 1) * canvas.width / cellCount
            canvas.fill(left: left, top: 0, width: right - left, height: height,
                        color: isWhite ? PixelCanvas.white : PixelCanvas.black)
        }
    }

    /// Reads the value back; `nil` when the check bits do not match (no strip, a scaled-away strip, a torn frame).
    /// `luma(column, row)` returns the 0…255 brightness of a pixel of a `width` × `height` frame.
    public static func decode(width: Int, height: Int, luma: (Int, Int) -> Int) -> UInt32? {
        guard width >= cellCount, height >= 8 else { return nil }
        let row = stripHeight(frameHeight: height) / 2
        var value: UInt32 = 0, check: UInt32 = 0
        for index in 0..<cellCount {
            let column = (2 * index + 1) * width / (2 * cellCount)
            let bit: UInt32 = luma(column, row) >= 128 ? 1 : 0
            if index < 32 { value = value << 1 | bit } else { check = check << 1 | bit }
        }
        return check == ~value ? value : nil
    }

    public static func decode(_ canvas: PixelCanvas) -> UInt32? {
        decode(width: canvas.width, height: canvas.height) { canvas.luma(column: $0, row: $1) }
    }
}
