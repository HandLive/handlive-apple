import Foundation

/// The character and part estimate under the message field (SMS-04 field 3): GSM-7 with 160 characters in one part and
/// 153 per part when there are several; any character outside GSM-7 (Vietnamese with diacritics, emoji) switches to
/// UCS-2 with 70 and 67. Characters of the GSM-7 extension table take two places. The phone's `divideMessage` makes
/// the final split; this is only the estimate shown before sending.
public struct SmsPartEstimate: Equatable, Sendable {
    public enum Encoding: Sendable, Equatable {
        case gsm7
        case ucs2
    }

    public let encoding: Encoding
    /// GSM-7 septets or UTF-16 code units.
    public let units: Int
    /// Number of SMS parts; 0 for an empty text.
    public let parts: Int
    /// Units that fit in `parts` parts (at least one part): 160, 306, 459… or 70, 134, 201…
    public let capacity: Int
}

public enum SmsPartCounter {
    public static let gsmSinglePart = 160
    public static let gsmPerPart = 153
    public static let ucsSinglePart = 70
    public static let ucsPerPart = 67

    public static func estimate(_ text: String) -> SmsPartEstimate {
        var septets = 0
        for scalar in text.unicodeScalars {
            if basic.contains(scalar) {
                septets += 1
            } else if extended.contains(scalar) {
                septets += 2
            } else {
                return estimate(units: text.utf16.count, encoding: .ucs2)
            }
        }
        return estimate(units: septets, encoding: .gsm7)
    }

    private static func estimate(units: Int, encoding: SmsPartEstimate.Encoding) -> SmsPartEstimate {
        let single = encoding == .gsm7 ? gsmSinglePart : ucsSinglePart
        let perPart = encoding == .gsm7 ? gsmPerPart : ucsPerPart
        let parts = units == 0 ? 0 : (units <= single ? 1 : (units + perPart - 1) / perPart)
        let capacity = parts <= 1 ? single : parts * perPart
        return SmsPartEstimate(encoding: encoding, units: units, parts: parts, capacity: capacity)
    }

    /// GSM 03.38 default alphabet (one septet each).
    static let basic: Set<Unicode.Scalar> = Set(
        ("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿"
            + "abcdefghijklmnopqrstuvwxyzäöñüà").unicodeScalars)

    /// GSM 03.38 extension table (escape + one septet each).
    static let extended: Set<Unicode.Scalar> = Set("\u{0C}^{}\\[~]|€".unicodeScalars)
}
