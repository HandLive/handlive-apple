import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The QR code of `PairingCard` (PAIR-01 field 1): `qr-ink` modules on `qr-paper` in every appearance (no glass, no
/// dark variant), `size-qr` on a side, `radius-card` corners, error correction level M. Modules are drawn at a whole
/// number of points without smoothing so the code stays sharp.
public struct PairingQRCode: View {
    private let image: CGImage?

    public init(_ text: String) {
        image = Self.cache.image(for: text)
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .fill(HLColorToken.qrPaper.palette.light.color)
            if let image {
                let side = Self.moduleAlignedSide(modules: image.width)
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
            }
        }
        .frame(width: HLSize.qr, height: HLSize.qr)
        .accessibilityHidden(true)
    }

    /// The largest whole multiple of the module count that leaves a quiet zone inside the card.
    static func moduleAlignedSide(modules: Int) -> CGFloat {
        let available = HLSize.qr - 2 * HLSpacing.space12
        guard modules > 0 else { return available }
        return CGFloat(Int(available) / modules * modules)
    }

    /// One image per code: the view is rebuilt every second while the countdown runs.
    private static let cache = QRImageCache()

    /// Black-on-white QR image of `text`, recolored to the tokens; one pixel per module.
    nonisolated static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let ink = ciColor(HLColorToken.qrInk.palette.light), let paper = ciColor(HLColorToken.qrPaper.palette.light)
        else { return nil }
        let colored = output.applyingFilter("CIFalseColor", parameters: ["inputColor0": ink, "inputColor1": paper])
        return CIContext().createCGImage(colored, from: colored.extent)
    }

    private nonisolated static func ciColor(_ value: HLRGBA) -> CIColor? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIColor(red: CGFloat(value.red) / 255, green: CGFloat(value.green) / 255, blue: CGFloat(value.blue) / 255,
                       alpha: CGFloat(value.alpha) / 255, colorSpace: space)
    }
}

/// Remembers the image of the last code.
private final class QRImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (text: String, image: CGImage?)?

    func image(for text: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let last, last.text == text { return last.image }
        let image = PairingQRCode.render(text)
        last = (text, image)
        return image
    }
}

#if !HL_COMMAND_LINE_TOOLS_ONLY
#Preview("PairingQRCode") {
    PairingQRCode("handlive://pair?v=1&pk=q83vEjRWeJC7zN3u_wARIjNEVWZ3iJmqu8zd7v8AESI"
        + "&ps=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&d=MacBook%20c%E1%BB%A7a%20Lan")
        .padding()
        .hlPreviewAppearance(.dark)
}
#endif
