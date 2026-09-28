import Testing
@testable import CameraSpikeKit

/// An owned BGRA buffer for the tests.
final class TestBuffer {
    let canvas: PixelCanvas
    private let storage: UnsafeMutableRawPointer

    init(width: Int, height: Int, padding: Int = 0) {
        let bytesPerRow = width * 4 + padding
        storage = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * height)
        canvas = PixelCanvas(base: storage, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    deinit { storage.deallocate() }
}

@Suite struct TimestampBarcodeTests {
    @Test(arguments: [UInt32(0), 1, 0x8000_0000, 0xDEAD_BEEF, UInt32.max])
    func roundTrip(value: UInt32) {
        let buffer = TestBuffer(width: 1280, height: 720, padding: 64)
        TestPattern.render(on: buffer.canvas, frameIndex: 7, stampMillis: value, clockText: "12:34:56.789")
        #expect(TimestampBarcode.decode(buffer.canvas) == value)
    }

    @Test func survivesNearestNeighbourScaling() {
        let source = TestBuffer(width: 1280, height: 720)
        TestPattern.render(on: source.canvas, frameIndex: 0, stampMillis: 123_456_789, clockText: "00:00:00.000")
        // A consumer that asked for 640×360 sees every other pixel.
        let scaled = TestBuffer(width: 640, height: 360)
        for row in 0..<360 {
            for column in 0..<640 {
                scaled.canvas.fill(left: column, top: row, width: 1, height: 1,
                                   color: source.canvas.pixel(column: column * 2, row: row * 2))
            }
        }
        #expect(TimestampBarcode.decode(scaled.canvas) == 123_456_789)
    }

    @Test func placeholderHasNoTimestamp() {
        let buffer = TestBuffer(width: 1280, height: 720)
        TestPattern.renderPlaceholder(on: buffer.canvas, frameIndex: 3)
        #expect(TimestampBarcode.decode(buffer.canvas) == nil)
    }

    @Test func blankFrameHasNoTimestamp() {
        #expect(TimestampBarcode.decode(TestBuffer(width: 1280, height: 720).canvas) == nil)
    }

    @Test func cellsCarryInvertedCheckBits() {
        let cells = TimestampBarcode.cells(for: 0b1011)
        #expect(cells.count == 64)
        #expect(Array(cells[28..<32]) == [true, false, true, true])
        #expect(zip(cells[0..<32], cells[32..<64]).allSatisfy { $0 != $1 })
    }
}

@Suite struct TestPatternDrawingTests {
    @Test func movingBoxAdvancesEightPixelsPerFrame() {
        let first = TestBuffer(width: 1280, height: 720), second = TestBuffer(width: 1280, height: 720)
        TestPattern.render(on: first.canvas, frameIndex: 10, stampMillis: 0, clockText: "")
        TestPattern.render(on: second.canvas, frameIndex: 11, stampMillis: 0, clockText: "")
        let laneRow = 720 * 3 / 4 + 5
        func boxLeft(_ canvas: PixelCanvas) -> Int? {
            (0..<1280).first { canvas.pixel(column: $0, row: laneRow) == PixelCanvas.white }
        }
        #expect(boxLeft(first.canvas) == 80)
        #expect(boxLeft(second.canvas) == 88)
    }

    @Test func clockDigitsAreDrawnInWhite() {
        let buffer = TestBuffer(width: 1280, height: 720)
        TestPattern.render(on: buffer.canvas, frameIndex: 0, stampMillis: 0, clockText: "88:88:88.888")
        let clockRows = (720 / 4)..<(720 / 4 + 160)
        let whitePixels = clockRows.reduce(0) { count, row in
            count + (0..<1280).filter { buffer.canvas.pixel(column: $0, row: row) == PixelCanvas.white }.count
        }
        #expect(whitePixels > 20_000)
    }

    @Test func drawingIsClippedToTheCanvas() {
        let buffer = TestBuffer(width: 64, height: 16)
        buffer.canvas.fill(left: -10, top: -10, width: 1000, height: 1000, color: PixelCanvas.white)
        #expect(buffer.canvas.pixel(column: 63, row: 15) == PixelCanvas.white)
        SevenSegmentText(height: 40, color: PixelCanvas.black).draw("0123456789:.-", left: 50, top: 10, on: buffer.canvas)
        #expect(buffer.canvas.pixel(column: 0, row: 0) == PixelCanvas.white)
    }

    @Test func textWidthAddsCharacterAdvances() {
        #expect(SevenSegmentText(height: 100, color: 0).width(of: "12:34.5") == 5 * 60 + 2 * 20)
    }
}
