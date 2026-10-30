import Foundation

// Bignum/field-arithmetic notation throughout (a, b, i, j, k, q, r, z — the usual textbook/RFC naming for this
// kind of code, e.g. RFC 7748/9380's own variable names).
// swiftlint:disable identifier_name

/// GF(2^255 − 19), the field Curve25519 lives in. CryptoKit has no field arithmetic, so `CPaceX25519SHA512`
/// (Elligator2, `calculate_generator`) needs its own. **Constant-time for Trang to audit**: every operation below
/// is a fixed sequence of arithmetic and bit masks — no `if`/`guard` branches or array indices derived from a
/// field value (which here can carry PIN-derived secrets), only from the loop counter or a compile-time-fixed
/// public exponent (`inverseExponent`/`legendreExponent`, same 255 iterations every call regardless of the
/// base). Reductions select between "subtract q" and "keep as is" with a bitmask (`select`), never a branch.
struct Field25519: Equatable {
    /// 4 limbs, little-endian (`limbs[0]` = bits 0–63); always held in canonical form (< q) between operations.
    var limbs: [UInt64]

    static let q = Field25519(limbs: [0xFFFF_FFFF_FFFF_FFED, 0xFFFF_FFFF_FFFF_FFFF,
                                       0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF])
    static let zero = Field25519(limbs: [0, 0, 0, 0])
    static let one = Field25519(limbs: [1, 0, 0, 0])

    /// Derived straight from `q.limbs` (not hand-transcribed hex, to rule out a copy mistake in a value this
    /// easy to get subtly wrong): subtract a small constant with its own tiny borrow chain, independent of the
    /// general `subRaw`/`reduceBounded` machinery below so these `static let`s can be computed before it runs.
    private static func minusSmallConstant(_ a: [UInt64], _ k: UInt64) -> [UInt64] {
        var diff = [UInt64](repeating: 0, count: 4)
        var borrow = k
        for i in 0..<4 {
            let (d, overflow) = a[i].subtractingReportingOverflow(borrow)
            diff[i] = d
            borrow = overflow ? 1 : 0
        }
        return diff
    }

    /// q − 2, the fixed public exponent of Fermat inversion (`a^(q-2) ≡ a^-1 mod q` for `a ≠ 0`).
    private static let inverseExponent: [UInt64] = minusSmallConstant(q.limbs, 2)

    /// (q − 1) / 2 — q is odd, so this is an exact shift. The fixed public exponent of Euler's criterion (the
    /// Legendre symbol: 1 if `a` is a nonzero square, q−1 (≡ −1) if not, 0 if `a` is 0).
    private static let legendreExponent: [UInt64] = {
        let qMinus1 = minusSmallConstant(q.limbs, 1)
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in (0..<4).reversed() {
            let nextCarry = qMinus1[i] & 1
            out[i] = (qMinus1[i] >> 1) | (carry << 63)
            carry = nextCarry
        }
        return out
    }()

    /// 2^-1 mod q = (q+1)/2 (q is odd, so q+1 is even) — needed by Elligator2's combination step, cheaper than
    /// inverting 2 every call. Two clearly separate passes, deliberately not fused with the shift below: the
    /// add-with-carry below ripples low→high, the halving above ripples high→low — fusing them into one loop
    /// direction is exactly the kind of off-by-direction bug this file has to avoid.
    static let inverseOfTwo: Field25519 = {
        var qPlusOne = q.limbs
        var carry: UInt64 = 1
        for i in 0..<4 {
            let (sum, overflow) = qPlusOne[i].addingReportingOverflow(carry)
            qPlusOne[i] = sum
            carry = overflow ? 1 : 0
        }
        var out = [UInt64](repeating: 0, count: 4)
        var shiftCarry: UInt64 = 0
        for i in (0..<4).reversed() {
            let nextShiftCarry = qPlusOne[i] & 1
            out[i] = (qPlusOne[i] >> 1) | (shiftCarry << 63)
            shiftCarry = nextShiftCarry
        }
        return Field25519(limbs: out)
    }()

    init(limbs: [UInt64]) {
        precondition(limbs.count == 4)
        self.limbs = limbs
    }

    /// RFC 7748 `decodeUCoordinate`: little-endian bytes, with the top bit of the last byte already masked off
    /// by the caller for a 255-bit field (so the value is always < 2^255, needing at most one reduction below).
    init(decodedLittleEndianBytes bytes: Data) {
        precondition(bytes.count == 32)
        var limbs = [UInt64](repeating: 0, count: 4)
        bytes.withUnsafeBytes { raw in
            for i in 0..<4 {
                limbs[i] = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))
            }
        }
        self.limbs = Field25519.reduceBounded(limbs)
    }

    var littleEndianBytes: Data {
        var data = Data(capacity: 32)
        for limb in limbs { withUnsafeBytes(of: limb.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    // MARK: - constant-time masks and selection

    /// All-zero or all-one mask from a 0/1 bit — no branch.
    @inline(__always) private static func mask(_ bit: UInt64) -> UInt64 { 0 &- bit }
    /// `a` when `maskValue` is all-one, `b` when all-zero.
    @inline(__always) private static func select(_ maskValue: UInt64, _ a: UInt64, _ b: UInt64) -> UInt64 {
        (a & maskValue) | (b & ~maskValue)
    }

    private static func selectLimbs(_ maskValue: UInt64, _ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        (0..<4).map { select(maskValue, a[$0], b[$0]) }
    }

    // MARK: - 4-limb add/subtract (raw, no reduction)

    private static func addRaw(_ a: [UInt64], _ b: [UInt64]) -> (sum: [UInt64], carry: UInt64) {
        var sum = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            sum[i] = s2
            carry = (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        return (sum, carry)
    }

    private static func subRaw(_ a: [UInt64], _ b: [UInt64]) -> (diff: [UInt64], borrow: UInt64) {
        var diff = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            diff[i] = d2
            borrow = (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        return (diff, borrow)
    }

    /// Brings a value that is at most a handful of multiples of q (as produced by `addRaw`/`subRaw`-based
    /// callers below) down to canonical [0, q): a fixed 4 rounds of "subtract q, keep the subtraction only if
    /// it didn't borrow" — always 4 rounds, never fewer, so the cost does not reveal how large the input was.
    private static func reduceBounded(_ value: [UInt64]) -> [UInt64] {
        var v = value
        for _ in 0..<4 {
            let (diff, borrow) = subRaw(v, q.limbs)
            v = selectLimbs(mask(1 &- borrow), diff, v)
        }
        return v
    }

    // MARK: - field add/sub (canonical in, canonical out)

    static func addMod(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let (sum, carry) = addRaw(a, b)
        // 2^256 ≡ 38 (mod q): fold a carry out of the raw add back in before reducing (defensive — unreachable
        // for two already-canonical < q inputs, since a+b < 2q < 2^256, but keeps the function correct on its
        // own terms rather than relying on that invariant).
        let (adjusted, _) = addRaw(sum, [38 &* carry, 0, 0, 0])
        return reduceBounded(adjusted)
    }

    static func subMod(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let (diff, borrow) = subRaw(a, b)
        let (diffPlusQ, _) = addRaw(diff, q.limbs) // wraps mod 2^256 on purpose; see Field25519Tests for the proof
        return reduceBounded(selectLimbs(mask(borrow), diffPlusQ, diff))
    }

    // MARK: - multiply (schoolbook 4×4 → 8 limbs, then fold mod q)

    /// Adds `value` into `result[index]`, rippling the carry across every remaining position up to a FIXED
    /// bound (`result.count`, never an early `while carry != 0` exit) — the number of limbs touched depends only
    /// on `index`/`result.count`, not on the carry pattern, so it cannot leak which limbs of a secret-derived
    /// value actually carried.
    private static func addAt(_ result: inout [UInt64], _ index: Int, _ value: UInt64) {
        var carry = value
        for i in index..<result.count {
            let (sum, overflow) = result[i].addingReportingOverflow(carry)
            result[i] = sum
            carry = overflow ? 1 : 0
        }
    }

    private static func mulRaw(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            for j in 0..<4 {
                let (hi, lo) = a[i].multipliedFullWidth(by: b[j])
                addAt(&result, i + j, lo)
                if i + j + 1 < 8 { addAt(&result, i + j + 1, hi) }
            }
        }
        return result
    }

    /// 4-limb value × small constant → 5 limbs (the 5th limb holds whatever doesn't fit in the low 4 — never
    /// truncated away, unlike a plain 4-limb multiply would).
    private static func mulBySmallConstant(_ a: [UInt64], _ k: UInt64) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: 5)
        for i in 0..<4 {
            let (hi, lo) = a[i].multipliedFullWidth(by: k)
            addAt(&result, i, lo)
            addAt(&result, i + 1, hi)
        }
        return result
    }

    /// `a * b mod q`. The raw product splits as `lo + hi · 2^256`; since `2^256 ≡ 38 (mod q)`, folding `38 · hi`
    /// into `lo` and repeating shrinks `hi` by roughly 58 bits each round. A fixed 6 rounds (not a data-dependent
    /// "until hi is 0" loop) comfortably drives it to 0 for any product of two < q values — confirmed by the
    /// full `cpace.json` suite, including the two near-`q` multiplications `calculate_generator` performs.
    static func mulMod(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let product = mulRaw(a, b)
        var lo = Array(product.prefix(4))
        var hi = Array(product.suffix(4))
        for _ in 0..<6 {
            let scaled = mulBySmallConstant(hi, 38)
            let (sum, carryOut) = addRaw(lo, Array(scaled.prefix(4)))
            lo = sum
            hi = [scaled[4] &+ carryOut, 0, 0, 0]
        }
        return reduceBounded(lo)
    }

    static func + (a: Field25519, b: Field25519) -> Field25519 { Field25519(limbs: addMod(a.limbs, b.limbs)) }
    static func - (a: Field25519, b: Field25519) -> Field25519 { Field25519(limbs: subMod(a.limbs, b.limbs)) }
    static func * (a: Field25519, b: Field25519) -> Field25519 { Field25519(limbs: mulMod(a.limbs, b.limbs)) }

    /// Square-and-multiply over a FIXED public 255-bit exponent (`inverseExponent`/`legendreExponent` below) —
    /// always 255 squarings, each followed by a masked (not branched) conditional multiply, so the sequence of
    /// operations never depends on `self` (the secret base).
    private func power(fixedExponentLimbs: [UInt64]) -> Field25519 {
        var result = Field25519.one
        for bitIndex in (0..<255).reversed() {
            result = result * result // Field25519 defines `*`, not `*=`. swiftlint:disable:this shorthand_operator
            let bit = (fixedExponentLimbs[bitIndex / 64] >> (bitIndex % 64)) & 1
            let candidate = result * self
            result = Field25519(limbs: Field25519.selectLimbs(Field25519.mask(bit), candidate.limbs, result.limbs))
        }
        return result
    }

    /// `self^-1 mod q` (0 maps to 0, matching Fermat's little theorem applied to `a^(q-2)`).
    func inverted() -> Field25519 { power(fixedExponentLimbs: Field25519.inverseExponent) }

    /// Euler's criterion: `1` if `self` is a nonzero square mod q, `q−1` (the field's `-1`) if a non-residue,
    /// `0` if `self` is `0`.
    func legendreSymbol() -> Field25519 { power(fixedExponentLimbs: Field25519.legendreExponent) }
}
// swiftlint:enable identifier_name
