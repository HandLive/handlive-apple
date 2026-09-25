import CoreImage
import Foundation
import Testing
@testable import HLDesignSystem

@Suite("PairingQRCode (PAIR-01 field 1)")
struct PairingQRCodeTests {
    static let uri = "handlive://pair?v=1&pk=q83vEjRWeJC7zN3u_wARIjNEVWZ3iJmqu8zd7v8AESI"
        + "&ps=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&d=MacBook%20c%E1%BB%A7a%20Lan"

    @Test("The rendered code decodes back to the URI; version ≤ 10 at level M; black on white")
    func roundTrip() throws {
        let image = try #require(PairingQRCode.render(Self.uri))
        // Version v has 17 + 4v modules; the generator adds a quiet zone around them.
        #expect(image.width <= 17 + 4 * 10 + 2 * 4)
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: scaled).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(messages == [Self.uri])
        #expect(Self.colors(of: image) == [0x000000FF, 0xFFFFFFFF]) // qr-ink, qr-paper
    }

    /// The distinct RGBA values of the image, drawn into an sRGB bitmap.
    static func colors(of image: CGImage) -> Set<UInt32> {
        let width = image.width, height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Set(pixels.map { UInt32(bigEndian: $0) })
    }

    @Test("Modules are drawn at a whole number of points inside the quiet zone")
    func moduleAlignment() {
        let side = PairingQRCode.moduleAlignedSide(modules: 57)
        #expect(side == 171 && side <= HLSize.qr - 24)
        #expect(PairingQRCode.moduleAlignedSide(modules: 0) == HLSize.qr - 24)
    }
}
