/// Large seven-segment text drawn with plain rectangles, so a frame can carry a readable clock without CoreText
/// (the Camera Extension draws its placeholder with it too). Supports the digits, ':', '.', '-' and ' '.
public struct SevenSegmentText {
    /// Segments a…g of each digit, bit 0 = a (top), then b (top right), c (bottom right), d (bottom), e (bottom
    /// left), f (top left), g (middle).
    static let digitSegments: [UInt8] = [
        0b011_1111, 0b000_0110, 0b101_1011, 0b100_1111, 0b110_0110,
        0b110_1101, 0b111_1101, 0b000_0111, 0b111_1111, 0b110_1111,
    ]

    /// Text height in pixels.
    public let height: Int
    public let color: UInt32

    public init(height: Int, color: UInt32) {
        self.height = height
        self.color = color
    }

    /// Width of one character cell; ':' and '.' take a third of a digit's.
    public func advance(of character: Character) -> Int {
        character == ":" || character == "." ? height / 5 : height * 3 / 5
    }

    public func width(of text: String) -> Int {
        text.reduce(0) { $0 + advance(of: $1) }
    }

    /// Draws `text` with its top-left corner at (`left`, `top`).
    public func draw(_ text: String, left: Int, top: Int, on canvas: PixelCanvas) {
        var pen = left
        for character in text {
            draw(character, left: pen, top: top, on: canvas)
            pen += advance(of: character)
        }
    }

    func draw(_ character: Character, left: Int, top: Int, on canvas: PixelCanvas) {
        let stroke = max(height / 9, 1)
        let glyphWidth = height * 3 / 5 - stroke   // leave a gap before the next character
        let half = (height - stroke) / 2
        var rects: [PixelRect]
        switch character {
        case ":":
            rects = [PixelRect(left, top + height / 3 - stroke, stroke, stroke),
                     PixelRect(left, top + 2 * height / 3, stroke, stroke)]
        case ".":
            rects = [PixelRect(left, top + height - stroke, stroke, stroke)]
        case "-":
            rects = [PixelRect(left, top + half, glyphWidth, stroke)]
        default:
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else { return }
            let segments = [
                PixelRect(left, top, glyphWidth, stroke),
                PixelRect(left + glyphWidth - stroke, top, stroke, half + stroke),
                PixelRect(left + glyphWidth - stroke, top + half, stroke, height - half),
                PixelRect(left, top + height - stroke, glyphWidth, stroke),
                PixelRect(left, top + half, stroke, height - half),
                PixelRect(left, top, stroke, half + stroke),
                PixelRect(left, top + half, glyphWidth, stroke),
            ]
            let mask = Self.digitSegments[digit]
            rects = segments.enumerated().filter { mask >> UInt8($0.offset) & 1 == 1 }.map(\.element)
        }
        for rect in rects { canvas.fill(rect, color: color) }
    }
}
