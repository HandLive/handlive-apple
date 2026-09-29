/// The frame the host pushes into the sink stream: colour bars, a box that moves 8 px per frame (stutter and dropped
/// frames show as jumps), the wall-clock time with milliseconds in large digits (for the photo/screenshot latency
/// method), the frame number, and the timestamp strip (for the automatic method).
public enum TestPattern {
    public static let width = 1280
    public static let height = 720
    public static let framesPerSecond = 30

    static let bars: [UInt32] = [
        PixelCanvas.color(red: 192, green: 192, blue: 192), PixelCanvas.color(red: 192, green: 192, blue: 0),
        PixelCanvas.color(red: 0, green: 192, blue: 192), PixelCanvas.color(red: 0, green: 192, blue: 0),
        PixelCanvas.color(red: 192, green: 0, blue: 192), PixelCanvas.color(red: 192, green: 0, blue: 0),
        PixelCanvas.color(red: 0, green: 0, blue: 192), PixelCanvas.color(red: 16, green: 16, blue: 16),
    ]

    /// Renders one frame.
    /// - Parameters:
    ///   - frameIndex: number of the frame since the feed started.
    ///   - stampMillis: host-clock milliseconds (low 32 bits) written into the timestamp strip.
    ///   - clockText: the wall-clock time to show, e.g. "14:03:27.415".
    public static func render(on canvas: PixelCanvas, frameIndex: Int64, stampMillis: UInt32, clockText: String) {
        let barWidth = (canvas.width + bars.count - 1) / bars.count
        for (index, color) in bars.enumerated() {
            canvas.fill(left: index * barWidth, top: 0, width: barWidth, height: canvas.height, color: color)
        }
        TimestampBarcode.draw(stampMillis, on: canvas)

        let clock = SevenSegmentText(height: canvas.height * 2 / 9, color: PixelCanvas.white)
        let clockTop = canvas.height / 4
        canvas.fill(left: 0, top: clockTop - clock.height / 6, width: canvas.width, height: clock.height * 4 / 3,
                    color: PixelCanvas.black)
        clock.draw(clockText, left: (canvas.width - clock.width(of: clockText)) / 2, top: clockTop, on: canvas)

        let boxSize = canvas.height / 12
        let travel = max(canvas.width - boxSize, 1)
        let boxLeft = Int((frameIndex * 8) % Int64(travel))
        let laneTop = canvas.height * 3 / 4
        canvas.fill(left: 0, top: laneTop, width: canvas.width, height: boxSize, color: PixelCanvas.black)
        canvas.fill(left: boxLeft, top: laneTop, width: boxSize, height: boxSize, color: PixelCanvas.white)

        let counter = SevenSegmentText(height: canvas.height / 16, color: PixelCanvas.white)
        let counterTop = canvas.height - counter.height * 2
        let digits = String(frameIndex % 1_000_000)
        canvas.fill(left: 0, top: counterTop - counter.height / 4, width: counter.width(of: digits) + counter.height,
                    height: counter.height * 3 / 2, color: PixelCanvas.black)
        counter.draw(digits, left: counter.height / 2, top: counterTop, on: canvas)
    }

    /// The frame the extension shows when no frame came from the sink for more than a second: dark grey with dashes,
    /// and no timestamp strip (so a self-check never mistakes it for a live frame).
    public static func renderPlaceholder(on canvas: PixelCanvas, frameIndex: Int64) {
        canvas.fill(left: 0, top: 0, width: canvas.width, height: canvas.height,
                    color: PixelCanvas.color(red: 40, green: 40, blue: 48))
        let dashes = SevenSegmentText(height: canvas.height / 6, color: PixelCanvas.color(red: 150, green: 150, blue: 160))
        let text = "--:--"
        dashes.draw(text, left: (canvas.width - dashes.width(of: text)) / 2, top: (canvas.height - dashes.height) / 2,
                    on: canvas)
        let dot = canvas.height / 30
        let dotLeft = Int(frameIndex % 30) * (canvas.width - dot) / 29
        canvas.fill(left: dotLeft, top: canvas.height - 3 * dot, width: dot, height: dot, color: dashes.color)
    }
}
