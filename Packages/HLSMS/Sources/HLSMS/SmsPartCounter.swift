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

    /// GSM 03.38 default alphabet (one septet each): printable ASCII except the extension characters and the backtick,
    /// LF, CR, and the Latin-1 and Greek letters of the table, by code point.
    static let basic: Set<Unicode.Scalar> = {
        let excluded = Set("`[\\]^{|}~".unicodeScalars)
        var scalars = Set((0x20...0x7E).compactMap(Unicode.Scalar.init).filter { !excluded.contains($0) })
        let latin: [UInt32] = [0x0A, 0x0D, 0xA1, 0xA3, 0xA4, 0xA5, 0xA7, 0xBF, 0xC4, 0xC5, 0xC6, 0xC7, 0xC9, 0xD1, 0xD6,
                               0xD8, 0xDC, 0xDF, 0xE0, 0xE4, 0xE5, 0xE6, 0xE8, 0xE9, 0xEC, 0xF1, 0xF2, 0xF6, 0xF8, 0xF9, 0xFC]
        let greek: [UInt32] = [0x393, 0x394, 0x398, 0x39B, 0x39E, 0x3A0, 0x3A3, 0x3A6, 0x3A8, 0x3A9]
        scalars.formUnion((latin + greek).compactMap(Unicode.Scalar.init))
        return scalars
    }()

    /// GSM 03.38 extension table (escape + one septet each): form feed, ^ { } \\ [ ~ ] | and the euro sign.
    static let extended: Set<Unicode.Scalar> = Set(
        [0x0C, 0x5B, 0x5C, 0x5D, 0x5E, 0x7B, 0x7C, 0x7D, 0x7E, 0x20AC].compactMap(Unicode.Scalar.init))
}
