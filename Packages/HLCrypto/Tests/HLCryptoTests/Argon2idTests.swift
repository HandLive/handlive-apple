import Foundation
import Testing
@testable import HLCrypto

@Suite("BLAKE2b and Argon2id (RFC 7693, RFC 9106)")
struct Argon2idTests {
    @Test("BLAKE2b-512 of \"\" and \"abc\" (RFC 7693 Appendix A and the reference test vectors)")
    func blake2b() {
        #expect(Hex.encode(Blake2b.hash(Data())) == "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419"
            + "d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        #expect(Hex.encode(Blake2b.hash(Data("abc".utf8))) == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
            + "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        // Several blocks and a partial last block, split across updates.
        var hasher = Blake2b(outputLength: 32)
        let data = Data((0..<300).map { UInt8($0 & 0xFF) })
        hasher.update(data.prefix(100))
        hasher.update(data.dropFirst(100))
        #expect(hasher.finalize() == Blake2b.hash(data, outputLength: 32))
    }

    @Test("Argon2id RFC 9106 §5.3: m = 32 KiB, t = 3, p = 4, secret and associated data")
    func rfc9106Vector() {
        let tag = Argon2id.hash(password: Data(repeating: 0x01, count: 32), salt: Data(repeating: 0x02, count: 16),
                                parameters: Argon2id.Parameters(passes: 3, memoryKiB: 32, lanes: 4, tagLength: 32),
                                secret: Data(repeating: 0x03, count: 8), associatedData: Data(repeating: 0x04, count: 12))
        #expect(Hex.encode(tag) == "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    @Test("K_pin parameters of 0.6.2 (64 MiB, t = 3, p = 4): the value OpenSSL and the Android app compute")
    func pairingParameters() {
        // About 0.1 s in release, several seconds in a debug test build; run it once. Salt = nonce_c ‖ nonce_s.
        let salt = Data((0..<64).map { UInt8($0) })
        let tag = Argon2id.hash(password: Data("042917".utf8), salt: salt, parameters: .pairingPIN)
        #expect(Hex.encode(tag) == "a3c171d44151caca5493ab545a4cd475e6492ba715500302369297e15178bc88")
    }

    @Test("Deterministic, and sensitive to the PIN and to either nonce")
    func sensitivity() {
        let small = Argon2id.Parameters(passes: 3, memoryKiB: 256, lanes: 4, tagLength: 32)
        let salt = Data(repeating: 0xAB, count: 64)
        let tag = Argon2id.hash(password: Data("482915".utf8), salt: salt, parameters: small)
        #expect(Argon2id.hash(password: Data("482915".utf8), salt: salt, parameters: small) == tag)
        #expect(Argon2id.hash(password: Data("482916".utf8), salt: salt, parameters: small) != tag)
        var serverNonceChanged = salt
        serverNonceChanged[63] ^= 1
        #expect(Argon2id.hash(password: Data("482915".utf8), salt: serverNonceChanged, parameters: small) != tag)
    }
}
