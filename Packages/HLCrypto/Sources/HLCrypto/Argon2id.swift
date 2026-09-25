import Foundation

/// Argon2id, version 0x13 (RFC 9106), for `K_pin` of the PIN pairing fallback (0.6.2): t = 3, m = 64 MiB, p = 4,
/// 32-byte output. CryptoKit has no Argon2. Lanes are filled one after the other (same result as in parallel);
/// the RFC 9106 §5.3 vector checks it.
public enum Argon2id {
    public struct Parameters: Sendable, Equatable {
        public let passes: Int
        public let memoryKiB: Int
        public let lanes: Int
        public let tagLength: Int

        public init(passes: Int, memoryKiB: Int, lanes: Int, tagLength: Int) {
            self.passes = passes
            self.memoryKiB = memoryKiB
            self.lanes = lanes
            self.tagLength = tagLength
        }

        /// 0.6.2 `K_pin`: t = 3, m = 64 MiB, p = 4, L = 32.
        public static let pairingPIN = Parameters(passes: 3, memoryKiB: 64 * 1024, lanes: 4, tagLength: 32)
    }

    static let version: UInt32 = 0x13
    static let type: UInt32 = 2
    static let blockWords = 128
    static let syncPoints = 4

    public static func hash(password: Data, salt: Data, parameters: Parameters, secret: Data = Data(),
                            associatedData: Data = Data()) -> Data {
        precondition(parameters.passes >= 1 && parameters.lanes >= 1 && parameters.tagLength >= 4)
        precondition(parameters.memoryKiB >= 8 * parameters.lanes, "at least 8 KiB per lane")
        let lanes = parameters.lanes
        let blockCount = 4 * lanes * (parameters.memoryKiB / (4 * lanes))
        let laneLength = blockCount / lanes
        let segmentLength = laneLength / syncPoints

        var h0 = Blake2b(outputLength: 64)
        for value in [UInt32(lanes), UInt32(parameters.tagLength), UInt32(parameters.memoryKiB),
                      UInt32(parameters.passes), version, type] { h0.update(le32(value)) }
        for field in [password, salt, secret, associatedData] {
            h0.update(le32(UInt32(field.count)))
            h0.update(field)
        }
        let seed = h0.finalize()

        let memory = UnsafeMutablePointer<UInt64>.allocate(capacity: blockCount * blockWords)
        defer {
            memory.update(repeating: 0, count: blockCount * blockWords) // do not leave PIN-derived memory behind
            memory.deallocate()
        }
        for lane in 0..<lanes {
            for column in 0..<2 {
                let block = variableHash(seed + le32(UInt32(column)) + le32(UInt32(lane)), length: 1024)
                load(block, into: memory + (lane * laneLength + column) * blockWords)
            }
        }
        let filler = SegmentFiller(memory: memory, lanes: lanes, laneLength: laneLength, segmentLength: segmentLength,
                                   blockCount: blockCount, passes: parameters.passes)
        for pass in 0..<parameters.passes {
            for slice in 0..<syncPoints {
                for lane in 0..<lanes { filler.fill(pass: pass, slice: slice, lane: lane) }
            }
        }
        var final = [UInt64](repeating: 0, count: blockWords)
        for lane in 0..<lanes {
            let last = memory + (lane * laneLength + laneLength - 1) * blockWords
            for word in 0..<blockWords { final[word] ^= last[word] }
        }
        var finalBytes = Data(capacity: 1024)
        for word in final { withUnsafeBytes(of: word.littleEndian) { finalBytes.append(contentsOf: $0) } }
        return variableHash(finalBytes, length: parameters.tagLength)
    }

    /// H' (RFC 9106 §3.3): BLAKE2b with a length prefix, chained 32 bytes at a time past 64 bytes.
    static func variableHash(_ input: Data, length: Int) -> Data {
        var first = Blake2b(outputLength: min(length, 64))
        first.update(le32(UInt32(length)))
        first.update(input)
        var previous = first.finalize()
        guard length > 64 else { return previous }
        var output = Data(previous.prefix(32))
        var remaining = length - 32
        while remaining > 64 {
            previous = Blake2b.hash(previous, outputLength: 64)
            output.append(previous.prefix(32))
            remaining -= 32
        }
        output.append(Blake2b.hash(previous, outputLength: remaining))
        return output
    }

    static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func load(_ bytes: Data, into block: UnsafeMutablePointer<UInt64>) {
        bytes.withUnsafeBytes { raw in
            for word in 0..<blockWords {
                block[word] = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self))
            }
        }
    }
}
