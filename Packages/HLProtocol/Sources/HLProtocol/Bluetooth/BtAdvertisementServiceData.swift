import Foundation

/// Scan-response service data, the app-controlled bytes after the UUID (0.4.5 "Advertisement"): `ver`(1) ‖
/// `psm`(2, uint16 LE) ‖ `hints`(4 × n, n = 0…`BT_ADV_MAX_HINTS`). Decoding never throws — an advertisement with
/// the wrong `ver` or a malformed length is simply not a candidate (0.4.5: "An advertisement with `ver` ≠ `0x01`
/// or with no matching hint is ignored"), unlike a transport record where a bad length closes the link.
public struct BtAdvertisementServiceData: Equatable, Sendable {
    public static let version: UInt8 = 0x01
    public static let maxHints = 2
    public static let hintSize = 4

    public let psm: UInt16
    public let hints: [Data]

    public init(psm: UInt16, hints: [Data]) {
        self.psm = psm
        self.hints = hints
    }

    /// `nil` when `ver` ≠ `BtAdvertisementServiceData.version` or the bytes don't fit the `ver ‖ psm ‖ 4×n` shape.
    public static func decode(_ bytes: Data) -> BtAdvertisementServiceData? {
        guard bytes.count >= 3, (bytes.count - 3).isMultiple(of: hintSize) else { return nil }
        let bytes = Array(bytes)
        guard bytes[0] == version else { return nil }
        let psm = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        var hints: [Data] = []
        var offset = 3
        while offset < bytes.count {
            hints.append(Data(bytes[offset..<offset + hintSize]))
            offset += hintSize
        }
        return BtAdvertisementServiceData(psm: psm, hints: hints)
    }

    public func encode() -> Data {
        var out = Data([Self.version, UInt8(psm & 0xFF), UInt8((psm >> 8) & 0xFF)])
        hints.forEach { out.append($0) }
        return out
    }
}
