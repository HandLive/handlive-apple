import Foundation
import Testing
@testable import HLCrypto

/// Direct sanity checks on `Field25519` itself, underneath `CPaceX25519SHA512Tests`' end-to-end vectors: these
/// catch a wrong-but-plausible arithmetic bug (a dropped carry limb, a reduction that doesn't fully land in
/// [0, q)) right at the operation that has it, rather than as an opaque mismatch several field operations later
/// in `calculate_generator`.
@Suite("Field25519 arithmetic sanity")
struct Field25519Tests {
    @Test("q - 1 is canonical, and (q-1) + 1 wraps to 0")
    func qMinusOneWrapsToZero() {
        let qMinusOne = Field25519.zero - Field25519.one
        #expect(qMinusOne + Field25519.one == Field25519.zero)
    }

    @Test("(q-1) * (q-1) == 1: multiplying two values close to q must fully reduce, not leave a stray multiple of q")
    func nearQMultiplicationReducesFully() {
        let qMinusOne = Field25519.zero - Field25519.one
        #expect(qMinusOne * qMinusOne == Field25519.one)
    }

    @Test("inverseOfTwo * 2 == 1, matching the derived constant used by Elligator2's combining step")
    func inverseOfTwoRoundTrips() {
        let two = Field25519(limbs: [2, 0, 0, 0])
        #expect(Field25519.inverseOfTwo * two == Field25519.one)
        #expect(two.inverted() == Field25519.inverseOfTwo)
    }

    @Test("a.inverted() * a == 1 for a handful of small, non-trivial values")
    func invertedRoundTrips() {
        for value in [2, 3, 5, 7, 123_456_789] {
            let element = Field25519(limbs: [UInt64(value), 0, 0, 0])
            #expect(element.inverted() * element == Field25519.one, "value=\(value)")
        }
    }

    @Test("legendreSymbol: 0 maps to 0; small squares are residues (1); 2 is a known non-residue mod 2^255-19")
    func legendreSymbolCases() {
        #expect(Field25519.zero.legendreSymbol() == Field25519.zero)
        let three = Field25519(limbs: [3, 0, 0, 0])
        #expect((three * three).legendreSymbol() == Field25519.one)
        // 2 is a non-square mod q (q ≡ 5 mod 8, so 2 is a non-residue by quadratic reciprocity) — the field's -1.
        let minusOne = Field25519.zero - Field25519.one
        #expect(Field25519(limbs: [2, 0, 0, 0]).legendreSymbol() == minusOne)
    }

    @Test("round-tripping through the 32-byte little-endian encoding preserves the value")
    func byteRoundTrip() {
        let value = Field25519(limbs: [0x1122_3344_5566_7788, 0x99AA_BBCC_DDEE_FF00, 1, 0])
        let decoded = Field25519(decodedLittleEndianBytes: value.littleEndianBytes)
        #expect(decoded == value)
    }
}
