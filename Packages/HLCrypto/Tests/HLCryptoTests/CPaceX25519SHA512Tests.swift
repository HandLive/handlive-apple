import Foundation
import Testing
@testable import HLCrypto

/// S7.1 CPace-X25519-SHA512 vectors (`cpace.json`): draft Appendix B.1's own vectors (`official_generator`,
/// `official_message`) check the raw algorithm against the spec, independent of HandLive; `handlive_pin` checks
/// 0.4.5's actual PIN usage end to end, including the HKDF-derived `K_bt_pinlink`/`K_bt_pin`, and a PIN with a
/// leading zero; `invalid_vectors` cover the one abort CPace itself performs (a low-order `Ya`/`Yb` — 0.4.5: "An
/// all-zero `K` → close without answer") and the two mismatches that are *not* self-aborting (a `sid` or PIN
/// differing between the two sides), which only surface downstream when the derived Noise psk fails to verify.
@Suite("CPace-X25519-SHA512 (0.4.5 PIN, cpace.json)")
struct CPaceX25519SHA512Tests {
    @Test("draft Appendix B.1.1: calculate_generator")
    func officialGenerator() throws {
        let vectors = try VectorFile("cpace.json").vectors.filter { $0["kind"] as? String == "official_generator" }
        #expect(vectors.count == 1)
        for vector in vectors {
            let generator = CPaceX25519SHA512.calculateGenerator(prs: try vector.hex("PRS"), ci: try vector.hex("CI"),
                                                                  sid: try vector.hex("sid"))
            #expect(Hex.encode(generator) == (try vector.string("g")), "\(vector.label)")
        }
    }

    @Test("draft Appendix B.1.2-B.1.7: message A/B, K, ISK (initiator/responder transcript)")
    func officialMessage() throws {
        let vectors = try VectorFile("cpace.json").vectors.filter { $0["kind"] as? String == "official_message" }
        #expect(vectors.count == 1)
        for vector in vectors {
            let prs = try vector.hex("PRS"), ci = try vector.hex("CI"), sid = try vector.hex("sid")
            let ada = try vector.hex("ADa"), adb = try vector.hex("ADb")
            let generator = CPaceX25519SHA512.calculateGenerator(prs: prs, ci: ci, sid: sid)
            #expect(Hex.encode(generator) == (try vector.string("g")), "\(vector.label)")
            let yaPub = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: try vector.hex("ya"), point: generator),
                                     "\(vector.label)")
            let ybPub = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: try vector.hex("yb"), point: generator),
                                     "\(vector.label)")
            #expect(Hex.encode(yaPub) == (try vector.string("Ya")), "\(vector.label)")
            #expect(Hex.encode(ybPub) == (try vector.string("Yb")), "\(vector.label)")
            let sharedSecret = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: try vector.hex("ya"), point: ybPub),
                                            "\(vector.label)")
            #expect(Hex.encode(sharedSecret) == (try vector.string("K")), "\(vector.label)")
            let isk = CPaceX25519SHA512.isk(sid: sid, k: sharedSecret, ya: yaPub, ada: ada, yb: ybPub, adb: adb)
            #expect(Hex.encode(isk) == (try vector.string("ISK_initiator_responder")), "\(vector.label)")
        }
    }

    @Test("HandLive PIN pairing (0.4.5): generator, Ya/Yb, K, ISK, K_bt_pinlink/K_bt_pin — normal PIN + leading-zero PIN")
    func handlivePin() throws {
        let vectors = try VectorFile("cpace.json").vectors.filter { $0["kind"] as? String == "handlive_pin" }
        #expect(vectors.count == 2)
        for vector in vectors {
            let prs = Data((try vector.string("pin")).utf8)
            let ci = Data((try vector.string("ci")).utf8)
            let sid = try vector.hex("n_s")
            let generator = CPaceX25519SHA512.calculateGenerator(prs: prs, ci: ci, sid: sid)
            #expect(Hex.encode(generator) == (try vector.string("g")), "\(vector.label)")
            let yaPub = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: try vector.hex("ya"), point: generator),
                                     "\(vector.label)")
            let ybPub = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: try vector.hex("yb"), point: generator),
                                     "\(vector.label)")
            #expect(Hex.encode(yaPub) == (try vector.string("Ya")), "\(vector.label)")
            #expect(Hex.encode(ybPub) == (try vector.string("Yb")), "\(vector.label)")
            let sharedSecret = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: try vector.hex("ya"), point: ybPub),
                                            "\(vector.label)")
            #expect(Hex.encode(sharedSecret) == (try vector.string("K")), "\(vector.label)")
            let isk = CPaceX25519SHA512.isk(sid: sid, k: sharedSecret, ya: yaPub, ada: Data(), yb: ybPub, adb: Data())
            #expect(Hex.encode(isk) == (try vector.string("ISK")), "\(vector.label)")
            let pinlink = HKDFSHA256.derive(ikm: isk, salt: sid, info: try vector.string("k_bt_pinlink_info"))
            #expect(Hex.encode(pinlink) == (try vector.string("k_bt_pinlink")), "\(vector.label)")
            let pin = HKDFSHA256.derive(ikm: isk, salt: sid, info: try vector.string("k_bt_pin_info"))
            #expect(Hex.encode(pin) == (try vector.string("k_bt_pin")), "\(vector.label)")
        }
    }

    @Test("Ya bậc thấp (0.4.5): S tính K = scalar_mult_vfy(yb, Ya) → nil, đóng kênh không trả lời")
    func lowOrderYa() throws {
        let vector = try #require(VectorFile("cpace.json").invalidVectors.first { $0["reason"] as? String == "low_order_ya" })
        let sharedSecret = CPaceX25519SHA512.scalarMultVfy(scalar: try vector.hex("yb"), point: try vector.hex("Ya_attacker"))
        #expect(sharedSecret == nil)
    }

    @Test("Yb bậc thấp (0.4.5): C tính K = scalar_mult_vfy(ya, Yb) → nil, đóng kênh không trả lời")
    func lowOrderYb() throws {
        let vector = try #require(VectorFile("cpace.json").invalidVectors.first { $0["reason"] as? String == "low_order_yb" })
        let sharedSecret = CPaceX25519SHA512.scalarMultVfy(scalar: try vector.hex("ya"), point: try vector.hex("Yb_attacker"))
        #expect(sharedSecret == nil)
    }

    @Test("sid khác nhau giữa C và S (0.4.5): CPace không tự abort, hai phía ra ISK khác nhau")
    func sidMismatch() throws {
        let vector = try #require(VectorFile("cpace.json").invalidVectors.first { $0["reason"] as? String == "sid_mismatch" })
        let prs = Data((try vector.string("pin")).utf8)
        let ci = Data("HLBTPIN1".utf8)
        let nsC = try vector.hex("n_s_c"), nsS = try vector.hex("n_s_s")
        let ya = try vector.hex("ya"), yb = try vector.hex("yb")
        // C sends Ya computed under its own generator (from nsC); S sends Yb under its own (from nsS).
        let generatorC = CPaceX25519SHA512.calculateGenerator(prs: prs, ci: ci, sid: nsC)
        let generatorS = CPaceX25519SHA512.calculateGenerator(prs: prs, ci: ci, sid: nsS)
        let yaPubC = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: ya, point: generatorC))
        let ybPubS = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: yb, point: generatorS))
        #expect(Hex.encode(yaPubC) == (try vector.string("Ya")))
        #expect(Hex.encode(ybPubS) == (try vector.string("Yb")))
        // Each side computes K from its own scalar and the peer's point as received over the wire, then its ISK
        // from its own sid.
        let sharedSecretC = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: ya, point: ybPubS))
        let sharedSecretS = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: yb, point: yaPubC))
        let iskC = CPaceX25519SHA512.isk(sid: nsC, k: sharedSecretC, ya: yaPubC, ada: Data(), yb: ybPubS, adb: Data())
        let iskS = CPaceX25519SHA512.isk(sid: nsS, k: sharedSecretS, ya: yaPubC, ada: Data(), yb: ybPubS, adb: Data())
        #expect(Hex.encode(iskC) == (try vector.string("isk_c")))
        #expect(Hex.encode(iskS) == (try vector.string("isk_s")))
        #expect(iskC != iskS)
    }

    @Test("PIN sai ở một phía (0.4.5): CPace không tự abort, hai phía ra ISK khác nhau")
    func wrongPin() throws {
        let vector = try #require(VectorFile("cpace.json").invalidVectors.first { $0["reason"] as? String == "wrong_pin" })
        let ci = Data("HLBTPIN1".utf8)
        let sid = try vector.hex("n_s")
        let ya = try vector.hex("ya"), yb = try vector.hex("yb")
        let generatorC = CPaceX25519SHA512.calculateGenerator(prs: Data((try vector.string("pin_c")).utf8), ci: ci, sid: sid)
        let generatorS = CPaceX25519SHA512.calculateGenerator(prs: Data((try vector.string("pin_s")).utf8), ci: ci, sid: sid)
        let yaPubC = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: ya, point: generatorC))
        let ybPubS = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: yb, point: generatorS))
        #expect(Hex.encode(yaPubC) == (try vector.string("Ya")))
        #expect(Hex.encode(ybPubS) == (try vector.string("Yb")))
        let sharedSecretC = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: ya, point: ybPubS))
        let sharedSecretS = try #require(CPaceX25519SHA512.scalarMultVfy(scalar: yb, point: yaPubC))
        let iskC = CPaceX25519SHA512.isk(sid: sid, k: sharedSecretC, ya: yaPubC, ada: Data(), yb: ybPubS, adb: Data())
        let iskS = CPaceX25519SHA512.isk(sid: sid, k: sharedSecretS, ya: yaPubC, ada: Data(), yb: ybPubS, adb: Data())
        #expect(Hex.encode(iskC) == (try vector.string("isk_c")))
        #expect(Hex.encode(iskS) == (try vector.string("isk_s")))
    }
}
