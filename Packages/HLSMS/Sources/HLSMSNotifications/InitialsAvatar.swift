import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Contacts-style letter avatar of a conversation (ThreadRow, communication notifications): up to two initials in
/// white on a gray gradient circle. Drawn with Core Graphics so the apps and the Notification Service Extension share it.
public enum InitialsAvatar {
    /// Up to two initials of a contact name; `nil` for a number, a short code or an empty name (they get a symbol).
    public static func initials(of name: String?) -> String? {
        guard let name else { return nil }
        let words = name.split { $0.isWhitespace || $0 == "," }.filter { word in word.first?.isLetter == true }
        guard let first = words.first?.first else { return nil }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// PNG of the avatar, `side` pixels square; `nil` when there are no initials.
    public static func pngData(for name: String?, side: Int = 120) -> Data? {
        guard let text = initials(of: name), let image = render(text, side: side) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func render(_ text: String, side: Int) -> CGImage? {
        let size = CGFloat(side)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.addEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        context.clip()
        let colors = [CGColor(srgbRed: 0.65, green: 0.67, blue: 0.72, alpha: 1),
                      CGColor(srgbRed: 0.52, green: 0.54, blue: 0.58, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: .zero, options: [])
        }
        let font = CTFontCreateUIFontForLanguage(.system, size * 0.42, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size * 0.42, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
