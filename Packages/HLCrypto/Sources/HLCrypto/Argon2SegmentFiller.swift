import Foundation

/// Fills one segment of the Argon2id memory (RFC 9106 §3.4): data-independent addressing in the first half of the
/// first pass, data-dependent afterwards; version 0x13 XORs new blocks into old ones from the second pass on.
struct SegmentFiller {
    let memory: UnsafeMutablePointer<UInt64>
    let lanes: Int
    let laneLength: Int
    let segmentLength: Int
    let blockCount: Int
    let passes: Int

    private static let words = Argon2id.blockWords

    func fill(pass: Int, slice: Int, lane: Int) {
        let independent = pass == 0 && slice < Argon2id.syncPoints / 2
        var input = [UInt64](repeating: 0, count: Self.words)
        var addresses = [UInt64](repeating: 0, count: Self.words)
        let zero = [UInt64](repeating: 0, count: Self.words)
        if independent {
            input[0] = UInt64(pass)
            input[1] = UInt64(lane)
            input[2] = UInt64(slice)
            input[3] = UInt64(blockCount)
            input[4] = UInt64(passes)
            input[5] = UInt64(Argon2id.type)
        }
        var startIndex = 0
        if pass == 0 && slice == 0 {
            startIndex = 2
            if independent { nextAddresses(&addresses, &input, zero) }
        }
        var current = lane * laneLength + slice * segmentLength + startIndex
        var previous = current % laneLength == 0 ? current + laneLength - 1 : current - 1
        for index in startIndex..<segmentLength {
            if current % laneLength == 1 { previous = current - 1 }
            let pseudoRandom: UInt64
            if independent {
                if index % Self.words == 0 { nextAddresses(&addresses, &input, zero) }
                pseudoRandom = addresses[index % Self.words]
            } else {
                pseudoRandom = memory[previous * Self.words]
            }
            var referenceLane = Int((pseudoRandom >> 32) % UInt64(lanes))
            if pass == 0 && slice == 0 { referenceLane = lane }
            let referenceIndex = alphaIndex(pass: pass, slice: slice, index: index,
                                            pseudoRandom: pseudoRandom & 0xFFFF_FFFF, sameLane: referenceLane == lane)
            fillBlock(previous: memory + previous * Self.words,
                      reference: memory + (referenceLane * laneLength + referenceIndex) * Self.words,
                      next: memory + current * Self.words, withXor: pass > 0)
            current += 1
            previous += 1
        }
    }

    /// `index_alpha` of the reference implementation: maps J1 into the area this block may reference.
    private func alphaIndex(pass: Int, slice: Int, index: Int, pseudoRandom: UInt64, sameLane: Bool) -> Int {
        let areaSize: Int
        if pass == 0 {
            if slice == 0 {
                areaSize = index - 1
            } else if sameLane {
                areaSize = slice * segmentLength + index - 1
            } else {
                areaSize = slice * segmentLength + (index == 0 ? -1 : 0)
            }
        } else if sameLane {
            areaSize = laneLength - segmentLength + index - 1
        } else {
            areaSize = laneLength - segmentLength + (index == 0 ? -1 : 0)
        }
        var relative = (pseudoRandom &* pseudoRandom) >> 32
        relative = UInt64(areaSize) - 1 - ((UInt64(areaSize) &* relative) >> 32)
        let start = pass == 0 || slice == Argon2id.syncPoints - 1 ? 0 : (slice + 1) * segmentLength
        return Int((UInt64(start) + relative) % UInt64(laneLength))
    }

    private func nextAddresses(_ addresses: inout [UInt64], _ input: inout [UInt64], _ zero: [UInt64]) {
        input[6] &+= 1
        input.withUnsafeMutableBufferPointer { inputBuffer in
            addresses.withUnsafeMutableBufferPointer { addressBuffer in
                zero.withUnsafeBufferPointer { zeroBuffer in
                    let zeroPointer = UnsafeMutablePointer(mutating: zeroBuffer.baseAddress!)
                    fillBlock(previous: zeroPointer, reference: inputBuffer.baseAddress!,
                              next: addressBuffer.baseAddress!, withXor: false)
                    fillBlock(previous: zeroPointer, reference: addressBuffer.baseAddress!,
                              next: addressBuffer.baseAddress!, withXor: false)
                }
            }
        }
    }

    /// G (RFC 9106 §3.5): R = X ⊕ Y; P on each row, then on each column; next = Z ⊕ R (⊕ next from pass 2 on).
    private func fillBlock(previous: UnsafeMutablePointer<UInt64>, reference: UnsafeMutablePointer<UInt64>,
                           next: UnsafeMutablePointer<UInt64>, withXor: Bool) {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 2 * Self.words) { buffer in
            let work = buffer.baseAddress!
            let saved = work + Self.words
            for word in 0..<Self.words {
                let value = reference[word] ^ previous[word]
                work[word] = value
                saved[word] = withXor ? value ^ next[word] : value
            }
            for row in 0..<8 {
                let base = 16 * row
                Self.permute(work, base, base + 1, base + 2, base + 3, base + 4, base + 5, base + 6, base + 7,
                             base + 8, base + 9, base + 10, base + 11, base + 12, base + 13, base + 14, base + 15)
            }
            for column in 0..<8 {
                let base = 2 * column
                Self.permute(work, base, base + 1, base + 16, base + 17, base + 32, base + 33, base + 48, base + 49,
                             base + 64, base + 65, base + 80, base + 81, base + 96, base + 97, base + 112, base + 113)
            }
            for word in 0..<Self.words { next[word] = saved[word] ^ work[word] }
        }
    }

    @inline(__always)
    // swiftlint:disable:next function_parameter_count
    private static func permute(_ v: UnsafeMutablePointer<UInt64>, _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int,
                                _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int, _ i8: Int, _ i9: Int, _ i10: Int,
                                _ i11: Int, _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        mix(v, i0, i4, i8, i12)
        mix(v, i1, i5, i9, i13)
        mix(v, i2, i6, i10, i14)
        mix(v, i3, i7, i11, i15)
        mix(v, i0, i5, i10, i15)
        mix(v, i1, i6, i11, i12)
        mix(v, i2, i7, i8, i13)
        mix(v, i3, i4, i9, i14)
    }

    /// GB with BlaMka: a + b + 2·lo32(a)·lo32(b).
    @inline(__always)
    // swiftlint:disable:next identifier_name
    private static func mix(_ v: UnsafeMutablePointer<UInt64>, _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        v[a] = blaMka(v[a], v[b])
        v[d] = (v[d] ^ v[a]).rotatedRight(32)
        v[c] = blaMka(v[c], v[d])
        v[b] = (v[b] ^ v[c]).rotatedRight(24)
        v[a] = blaMka(v[a], v[b])
        v[d] = (v[d] ^ v[a]).rotatedRight(16)
        v[c] = blaMka(v[c], v[d])
        v[b] = (v[b] ^ v[c]).rotatedRight(63)
    }

    @inline(__always)
    // swiftlint:disable:next identifier_name
    private static func blaMka(_ x: UInt64, _ y: UInt64) -> UInt64 {
        x &+ y &+ 2 &* (x & 0xFFFF_FFFF) &* (y & 0xFFFF_FFFF)
    }
}
