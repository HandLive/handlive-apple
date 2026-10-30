import Foundation

/// Plaintext của một khung vận chuyển (0.4.5 "Transport records and channels"), trước khi mã hoá / sau khi giải
/// mã: `chan`(1) ‖ `flags`(1, bit0 `more`, bit1 `long`) ‖ `dlen`(2 BE) ‖ `data` ‖ đệm 0 tới cỡ nhỏ nhất trong
/// `BtLinkConstants.paddedPlaintextSizes` chứa đủ khung.
public struct BtTransportFrame: Equatable, Sendable {
    public let chan: Int
    public let more: Bool
    public let long: Bool
    public let data: Data

    public init(chan: Int, more: Bool, long: Bool, data: Data) {
        self.chan = chan
        self.more = more
        self.long = long
        self.data = data
    }

    private static let flagMore = 0x01
    private static let flagLong = 0x02

    /// Cận `dlen`: làn dài (control, `long`) hoặc bulk (`chan` = 0x02) → `bulkFragmentMax`; làn ngắn → `fragmentMax`.
    public static func maxDlen(chan: Int, long: Bool) -> Int {
        chan == BtLinkConstants.chanBulk || long ? BtLinkConstants.bulkFragmentMax : BtLinkConstants.fragmentMax
    }

    public static func paddedSize(for unpaddedSize: Int) -> Int {
        guard let tier = BtLinkConstants.paddedPlaintextSizes.first(where: { $0 >= unpaddedSize }) else {
            preconditionFailure("no padded tier holds \(unpaddedSize) bytes")
        }
        return tier
    }

    /// Dựng plaintext đã đệm sẵn để mã hoá; bên gọi (bộ lập lịch/mux) lo việc cắt mảnh đúng cận trước.
    public static func encode(chan: Int, more: Bool, long: Bool, data: Data) -> Data {
        precondition(data.count <= maxDlen(chan: chan, long: long),
                    "dlen \(data.count) exceeds bound for chan=\(chan) long=\(long)")
        let padded = paddedSize(for: BtLinkConstants.frameHeaderSize + data.count)
        var flags = 0
        if more { flags |= flagMore }
        if long { flags |= flagLong }
        var plaintext = Data(count: padded)
        plaintext[0] = UInt8(chan)
        plaintext[1] = UInt8(flags)
        plaintext[2] = UInt8((data.count >> 8) & 0xFF)
        plaintext[3] = UInt8(data.count & 0xFF)
        plaintext.replaceSubrange(BtLinkConstants.frameHeaderSize..<(BtLinkConstants.frameHeaderSize + data.count),
                                  with: data)
        return plaintext
    }

    /// `plaintext` đã qua xác thực tag; kiểm mọi luật của 0.4.5 trước khi trả khung — không trả lời, đóng kênh khi sai.
    public static func decode(_ plaintext: Data) throws -> BtTransportFrame {
        guard BtLinkConstants.paddedPlaintextSizes.contains(plaintext.count) else {
            throw BtLinkError("unexpected plaintext size \(plaintext.count)")
        }
        let bytes = Array(plaintext)
        let chan = Int(bytes[0])
        guard chan == BtLinkConstants.chanControl || chan == BtLinkConstants.chanBulk else {
            throw BtLinkError("unknown chan \(chan)")
        }
        let flags = Int(bytes[1])
        let more = flags & flagMore != 0
        let long = flags & flagLong != 0
        // Luật "more=1 với long=0 → đóng kênh" chỉ áp dụng cho làn ngắn của control (chan=0x01); bulk
        // (chan=0x02) không dùng bit `long` nhưng vẫn hợp lệ cắt mảnh nhiều `more=1` (0.4.7).
        if chan == BtLinkConstants.chanControl && more && !long { throw BtLinkError("more without long") }
        let dlen = (Int(bytes[2]) << 8) | Int(bytes[3])
        let maxDlen = maxDlen(chan: chan, long: long)
        if dlen > maxDlen { throw BtLinkError("dlen \(dlen) exceeds bound \(maxDlen) for chan=\(chan) long=\(long)") }
        let dataEnd = BtLinkConstants.frameHeaderSize + dlen
        if dataEnd > plaintext.count { throw BtLinkError("dlen \(dlen) overflows frame") }
        let data = plaintext.subdata(in: BtLinkConstants.frameHeaderSize..<dataEnd)
        return BtTransportFrame(chan: chan, more: more, long: long, data: data)
    }
}
