import Foundation

/// BLAKE2b (RFC 7693), unkeyed, 1–64 byte output: the hash inside Argon2 (RFC 9106 §3.2). CryptoKit has no BLAKE2.
public struct Blake2b {
    static let iv: [UInt64] = [
        0x6A09_E667_F3BC_C908, 0xBB67_AE85_84CA_A73B, 0x3C6E_F372_FE94_F82B, 0xA54F_F53A_5F1D_36F1,
        0x510E_527F_ADE6_82D1, 0x9B05_688C_2B3E_6C1F, 0x1F83_D9AB_FB41_BD6B, 0x5BE0_CD19_137E_2179,
    ]

    static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    private var state: [UInt64]
    private var buffer = [UInt8]()
    private var counter: UInt64 = 0
    private let outputLength: Int

    public init(outputLength: Int = 64) {
        precondition((1...64).contains(outputLength), "BLAKE2b output is 1…64 bytes")
        self.outputLength = outputLength
        state = Self.iv
        state[0] ^= 0x0101_0000 ^ UInt64(outputLength)
    }

    public mutating func update(_ data: some Sequence<UInt8>) {
        buffer.append(contentsOf: data)
        // Keep the last block (possibly full) for `finalize`, which compresses it with the final flag.
        while buffer.count > 128 {
            counter &+= 128
            compress(Array(buffer[0..<128]), last: false)
            buffer.removeFirst(128)
        }
    }

    public mutating func finalize() -> Data {
        counter &+= UInt64(buffer.count)
        compress(buffer + [UInt8](repeating: 0, count: 128 - buffer.count), last: true)
        var output = Data(capacity: 64)
        for word in state { withUnsafeBytes(of: word.littleEndian) { output.append(contentsOf: $0) } }
        return output.prefix(outputLength)
    }

    public static func hash(_ data: some Sequence<UInt8>, outputLength: Int = 64) -> Data {
        var hasher = Blake2b(outputLength: outputLength)
        hasher.update(data)
        return hasher.finalize()
    }

    private mutating func compress(_ block: [UInt8], last: Bool) {
        var message = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 {
            var word: UInt64 = 0
            for byte in 0..<8 { word |= UInt64(block[index * 8 + byte]) << (8 * UInt64(byte)) }
            message[index] = word
        }
        var work = state + Self.iv
        work[12] ^= counter
        if last { work[14] = ~work[14] }
        for round in 0..<12 {
            let order = Self.sigma[round % 10]
            Self.mix(&work, 0, 4, 8, 12, message[order[0]], message[order[1]])
            Self.mix(&work, 1, 5, 9, 13, message[order[2]], message[order[3]])
            Self.mix(&work, 2, 6, 10, 14, message[order[4]], message[order[5]])
            Self.mix(&work, 3, 7, 11, 15, message[order[6]], message[order[7]])
            Self.mix(&work, 0, 5, 10, 15, message[order[8]], message[order[9]])
            Self.mix(&work, 1, 6, 11, 12, message[order[10]], message[order[11]])
            Self.mix(&work, 2, 7, 8, 13, message[order[12]], message[order[13]])
            Self.mix(&work, 3, 4, 9, 14, message[order[14]], message[order[15]])
        }
        for index in 0..<8 { state[index] ^= work[index] ^ work[index + 8] }
    }

    @inline(__always)
    // swiftlint:disable:next function_parameter_count identifier_name
    private static func mix(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = (v[d] ^ v[a]).rotatedRight(32)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotatedRight(24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = (v[d] ^ v[a]).rotatedRight(16)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotatedRight(63)
    }
}

extension UInt64 {
    @inline(__always)
    func rotatedRight(_ count: UInt64) -> UInt64 {
        (self >> count) | (self << (64 - count))
    }
}
