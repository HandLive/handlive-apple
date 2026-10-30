import CryptoKit
import Foundation

/// CPACE-X25519-SHA512 (draft-irtf-cfrg-cpace-21 Appendix B.1 suite `G_X25519`): `calculate_generator`
/// (Elligator2, Appendix A.5), `scalar_mult_vfy` (X25519 with low-order-point rejection, Appendix A.4) and `ISK`
/// (section 7.2) — how HandLive pairs by PIN over Bluetooth with no network (0.4.5 "PIN (PAIR-01 flow C)"), so
/// the PIN itself never crosses the air. Only the initiator/responder transcript (`transcriptIR`) is
/// implemented: HandLive always has a fixed role (C = M-APP sends `cpace1` first, S = A-SVC answers with
/// `cpace2`), never the draft's parallel variant (`transcript_oc`). Field arithmetic: `Field25519`.
public enum CPaceX25519SHA512 {
    static let dsi = Data("CPace255".utf8)
    static let dsiISK = dsi + Data("_ISK".utf8)
    /// SHA-512's own block size — `generatorString` zero-pads up to this so the hash's timing does not depend
    /// on the real length of `prs` (a secret PIN).
    private static let hashInputBlockBytes = 128
    private static let fieldSizeBytes = 32

    /// LEB128 length ‖ data (draft Appendix A.1.1).
    private static func prependLength(_ data: Data) -> Data {
        var length = data.count
        var encoded = Data()
        while true {
            encoded.append(length < 128 ? UInt8(length) : UInt8((length & 0x7F) + 0x80))
            length >>= 7
            if length == 0 { break }
        }
        return encoded + data
    }

    /// "length-value": each part prefixed with its own LEB128 length (draft Appendix A.1.3).
    private static func lengthValueConcat(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0.append(prependLength($1)) }
    }

    /// Draft Appendix A.2: `lv_cat(DSI, PRS, zero_bytes(len_zpad), CI, sid)` — the zero padding makes `DSI ‖ PRS`
    /// fill the first hash block exactly, so SHA-512's compression-function call count (and so its timing)
    /// stays the same regardless of the real PIN length.
    private static func generatorString(prs: Data, ci: Data, sid: Data) -> Data {
        let lenZpad = max(0, hashInputBlockBytes - 1 - prependLength(prs).count - prependLength(dsi).count)
        return lengthValueConcat(dsi, prs, Data(count: lenZpad), ci, sid)
    }

    /// RFC 7748 `decodeUCoordinate` for a 255-bit field (draft Appendix A.4): mask off the unused top bit of the
    /// last byte of a little-endian 32-byte value.
    private static func decodeUCoordinate(_ bytes: Data) -> Field25519 {
        var masked = bytes
        masked[masked.index(masked.startIndex, offsetBy: 31)] &= 0x7F
        return Field25519(decodedLittleEndianBytes: masked)
    }

    // Variable names below match the draft's own Appendix A.5 notation (A, Z, r, v) so the code can be checked
    // against it directly.
    // swiftlint:disable identifier_name
    /// Draft Appendix A.5 (`map_to_curve_elligator2`), specialised to Curve25519 (`A = 486662`, `Z = 2`, the
    /// `find_z_ell2` result for this curve, RFC 9380) — maps a field element straight to a Montgomery
    /// u-coordinate, the simplification CPace uses since it never needs the full point, only `u`. `epsilon`
    /// (the Legendre symbol) is already the field's own `1`/`q−1`(≡`-1`)/`0`, so it is used directly as a field
    /// value in the combining step below — no branch on it, unlike a naive port of the draft's pseudocode.
    private static func elligator2(_ r: Field25519) -> Field25519 {
        let a = Field25519(limbs: [486_662, 0, 0, 0])
        let z = Field25519(limbs: [2, 0, 0, 0])
        let denominator = Field25519.one + (z * r * r)
        let v = Field25519.zero - (a * denominator.inverted())
        let rhs = (v * v * v) + (a * v * v) + v
        let epsilon = rhs.legendreSymbol()
        let oneMinusEpsilon = Field25519.one - epsilon
        return (epsilon * v) - (oneMinusEpsilon * a * Field25519.inverseOfTwo)
    }
    // swiftlint:enable identifier_name

    /// `G.calculate_generator(SHA-512, PRS, CI, sid)` of suite `G_X25519` (0.4.5: `g = calculate_generator(...)`,
    /// draft §3.2.1). `prs`/`ci`/`sid` have no fixed length in the draft itself — the official Appendix B.1
    /// vectors use a 16-byte `sid`; HandLive's own usage (0.4.5 "PIN") always passes a 32-byte `n_s`.
    public static func calculateGenerator(prs: Data, ci: Data, sid: Data) -> Data {
        let hash = Data(SHA512.hash(data: generatorString(prs: prs, ci: ci, sid: sid)))
        let r = decodeUCoordinate(hash.prefix(fieldSizeBytes)) // swiftlint:disable:this identifier_name
        return elligator2(r).littleEndianBytes
    }

    /// `G_X25519.scalar_mult_vfy = X25519(scalar, point)`; `nil` on the draft's "G.I — abort" condition (`point`
    /// is a low-order point, so the shared secret would be all-zero — 0.4.5: "An all-zero `K` → close without
    /// answer"). CryptoKit's `sharedSecretFromKeyAgreement` already throws exactly in that case (confirmed
    /// against the draft's own low-order points via `cpace.json`'s `low_order_ya`/`low_order_yb` vectors), so
    /// catching its error is enough — no separate low-order check is needed here.
    public static func scalarMultVfy(scalar: Data, point: Data) -> Data? {
        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: point),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else { return nil }
        return shared.withUnsafeBytes { Data($0) }
    }

    /// Draft Appendix A.3.4, initiator/responder order (`transcript_ir`) — fixed, since HandLive's C always
    /// initiates and S always responds (0.4.5 "PIN").
    public static func transcriptIR(ya: Data, ada: Data, yb: Data, adb: Data) -> Data {
        lengthValueConcat(ya, ada) + lengthValueConcat(yb, adb)
    }

    /// `ISK = SHA-512(lv_cat(DSI ‖ "_ISK", sid, K) ‖ transcript_ir(Ya, ADa, Yb, ADb))` (draft section 7.2).
    /// 6 fields is the draft's own ISK signature (sid, K, Ya, ADa, Yb, ADb); `k` below matches the draft's `K`.
    public static func isk( // swiftlint:disable:this function_parameter_count
        sid: Data, k: Data, ya: Data, ada: Data, yb: Data, adb: Data // swiftlint:disable:this identifier_name
    ) -> Data {
        let message = lengthValueConcat(dsiISK, sid, k) + transcriptIR(ya: ya, ada: ada, yb: yb, adb: adb)
        return Data(SHA512.hash(data: message))
    }
}
