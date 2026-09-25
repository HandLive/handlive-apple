import Foundation
import Testing
@testable import HLCrypto

/// PAIR-01 byte strings and MACs (API 3–5, 0.6.2). The expected values are those of the Android implementation's
/// test (`PairingAuthDerivationTest.kt`), computed independently with Python `hmac`/`hashlib` from the same inputs.
@Suite("Pairing transcript, MACs, prk_check and attestation (PAIR-01, 0.6.2)")
struct PairingAuthDerivationTests {
    static let pairId = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    static let createdAt: Int64 = 1_727_150_003_210
    let client = PairingParty(deviceId: "5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718", nonce: Data((0..<32).map { UInt8($0) }),
                              signingPublicKey: Data(repeating: 0x11, count: 32),
                              dhPublicKey: Data(repeating: 0x22, count: 32), name: "MacBook của Lan")
    let server = PairingParty(deviceId: "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f",
                              nonce: Data((0..<32).map { UInt8($0 + 32) }),
                              signingPublicKey: Data(repeating: 0x33, count: 32),
                              dhPublicKey: Data(repeating: 0x44, count: 32), name: "Pixel của Lan")

    func transcript() throws -> Data {
        try PairingAuthDerivation.offerTranscript(client: client, server: server, tlsSHA256: Data(repeating: 0x55, count: 32))
    }

    func authKey() -> Data {
        PairingAuthDerivation.authKey(secret: Data(repeating: 0x66, count: 32), clientNonce: client.nonce,
                                      serverNonce: server.nonce)
    }

    @Test("T_offer, K_pa and the offer MAC")
    func offer() throws {
        let transcript = try transcript()
        #expect(transcript.count == 302)
        #expect(Hex.encode(HMACSHA256.sha256(transcript))
            == "e86712064866f453dab015a4c9fa26db8e90fba670c6da9e56843a66c5f1caa0")
        #expect(Hex.encode(authKey()) == "681841cf55cdc0cfe256d293d4a7da6f93d4a6e3b82548dee262da42f4b1e03f")
        #expect(Hex.encode(PairingAuthDerivation.offerMac(authKey: authKey(), transcript: transcript))
            == "c85231976b4c876e159d8b9200950ed85b7af2ecb688742617be08b6b3316eb3")
    }

    @Test("Confirm and done MACs, prk_check of both sides")
    func confirmAndDone() throws {
        let confirm = try PairingAuthDerivation.confirmMac(
            authKey: authKey(), transcript: try transcript(), pairId: Self.pairId, createdAt: Self.createdAt,
            clientSignature: Data(repeating: 0x77, count: 64))
        #expect(Hex.encode(confirm) == "a17c1eadf652878f3b9092285bad72a60dccb3e4b917046e9205ddaaf1e13a69")
        let done = try PairingAuthDerivation.doneMac(authKey: authKey(), pairId: Self.pairId,
                                                     serverSignature: Data(repeating: 0x88, count: 64))
        #expect(Hex.encode(done) == "1bd5207767db43716e5ce541c2d1d590fd39208b6b50e9f94c825e68b92d443e")
        let prk = Data(repeating: 0x99, count: 32)
        #expect(Hex.encode(try PairingAuthDerivation.prkCheck(prk: prk, pairId: Self.pairId, role: .client))
            == "5bc47f03f21deff98029ae52055c0be38adf408af776de9d29e9f75cd9ced5e3")
        #expect(Hex.encode(try PairingAuthDerivation.prkCheck(prk: prk, pairId: Self.pairId, role: .server))
            == "3585200b8cb4d68ce91530d330479a6d6ddc3eafa6c45142e651a7bdbe53e0f7")
    }

    @Test("Attestation layout and its security code")
    func attestation() throws {
        let attestation = try PairingAuthDerivation.attestation(PairingAttestationFields(
            pairId: Self.pairId, androidDeviceId: server.deviceId, clientDeviceId: client.deviceId,
            androidSigningKey: server.signingPublicKey, clientSigningKey: client.signingPublicKey,
            createdAt: Self.createdAt))
        #expect(Hex.encode(attestation) == "484c50414952313f2b1c4d5e6f4a7b8c9d0e1f2a3b4c5d8c7d6e5f4a3b8c2d9e1f0a1b2c3d4e5f"
            + "5b1f8c2e9a4d8e6fa1b2c3d4e5f60718" + String(repeating: "33", count: 32) + String(repeating: "11", count: 32)
            + "000001922229940a")
        #expect(Hex.encode(HMACSHA256.sha256(attestation)).prefix(8) == "fc647e0b")
    }

    @Test("Wrong sizes and malformed uuids are refused")
    func refusals() {
        var short = client
        short = PairingParty(deviceId: short.deviceId, nonce: Data(count: 31), signingPublicKey: short.signingPublicKey,
                             dhPublicKey: short.dhPublicKey, name: short.name)
        #expect(throws: CryptoError.self) {
            try PairingAuthDerivation.offerTranscript(client: short, server: server, tlsSHA256: Data(count: 32))
        }
        #expect(throws: (any Error).self) {
            try PairingAuthDerivation.prkCheck(prk: Data(count: 32), pairId: "not-a-uuid", role: .client)
        }
        #expect(throws: CryptoError.fieldTooLong) {
            try PairingAuthDerivation.str(String(repeating: "a", count: 65_536))
        }
    }

    @Test("K_pin composes Argon2id over the PIN and both nonces")
    func pinKey() {
        let small = Argon2id.Parameters(passes: 1, memoryKiB: 64, lanes: 4, tagLength: 32)
        let key = PairingAuthDerivation.pinKey(pin: "042917", clientNonce: client.nonce, serverNonce: server.nonce,
                                               parameters: small)
        #expect(key == Argon2id.hash(password: Data("042917".utf8), salt: client.nonce + server.nonce, parameters: small))
    }

    @Test("TXT pr, PIN and secret generators")
    func codes() {
        #expect(PairingAuthDerivation.pairingRequestHint(clientDHPublicKey: Data(repeating: 0x22, count: 32)) == "9f72ea0c")
        let pins = (0..<200).map { _ in PairingCodes.newPIN() }
        #expect(pins.allSatisfy { $0.count == 6 && $0.allSatisfy(\.isASCIIDigit) })
        #expect(Set(pins).count > 150)
        #expect(PairingCodes.newPairingSecret().count == 32 && PairingCodes.newPairingSecret() != PairingCodes.newPairingSecret())
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
