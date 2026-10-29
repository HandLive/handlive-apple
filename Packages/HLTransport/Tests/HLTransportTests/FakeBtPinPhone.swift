import Foundation
import HLCrypto
import HLProtocol
@testable import HLTransport

/// Android's side of a Bluetooth PIN pairing link (API 12) for tests: `challenge`, CPace responder (`cpace2`),
/// the Noise responder with its own `K_bt_pinlink` — `reject` when `noise1` does not verify — then
/// `FakePairingPhone` on the secured channel with `K_bt_pin` in place of the QR secret.
final class FakeBtPinPhone: @unchecked Sendable {
    enum Behavior { case honest, lowOrderCpace2 }
    enum Outcome: Equatable { case paired, rejectedNoise1, closedAfterCpace2, failed(String) }

    let clientEnd: FakeBluetoothByteStream
    private let phoneEnd: FakeBluetoothByteStream
    private let pin: String
    private let nS: Data
    private let yb: Data
    private let behavior: Behavior
    private let lock = NSLock()
    private var ya: Data?
    private(set) var pairingPhone = FakePairingPhone(window: .qr(secret: Data(count: 32), clientDHKey: Data()))

    var receivedYa: Data? { lock.withLock { ya } }

    init(pin: String, nS: Data = PairingCodes.newNonce(), yb: Data = X25519.generatePrivateKey(),
         behavior: Behavior = .honest) {
        (clientEnd, phoneEnd) = FakeBluetoothByteStream.pair()
        self.pin = pin
        self.nS = nS
        self.yb = yb
        self.behavior = behavior
    }

    func serveAndPair() async throws -> Outcome {
        try await phoneEnd.write(Self.record(BtPreauthRecord.kindChallenge, nS))
        let cpace1 = try await readRecord()
        guard cpace1.kind == BtPreauthRecord.kindCpace1 else { return .failed("expected cpace1") }
        lock.withLock { ya = cpace1.payload }
        if behavior == .lowOrderCpace2 {
            try await phoneEnd.write(Self.record(BtPreauthRecord.kindCpace2, Data(count: 32)))
            return (try? await readRecord()) == nil ? .closedAfterCpace2 : .failed("Mac went on after a low-order Yb")
        }
        let generator = CPaceX25519SHA512.calculateGenerator(prs: Data(pin.utf8), ci: Data("HLBTPIN1".utf8), sid: nS)
        guard let ybPub = CPaceX25519SHA512.scalarMultVfy(scalar: yb, point: generator),
              let sharedK = CPaceX25519SHA512.scalarMultVfy(scalar: yb, point: cpace1.payload) else {
            return .failed("cpace")
        }
        try await phoneEnd.write(Self.record(BtPreauthRecord.kindCpace2, ybPub))
        let isk = CPaceX25519SHA512.isk(sid: nS, k: sharedK, ya: cpace1.payload, ada: Data(), yb: ybPub, adb: Data())
        let keys = BtPinPairingKeys.derive(isk: isk, nS: nS)

        let noise1 = try await readRecord()
        guard noise1.kind == BtPreauthRecord.kindNoise1,
              let answer = try NoiseNNpsk0Responder.respond(message1: noise1.payload, psk: keys.linkKey,
                                                            prologue: NoiseNNpsk0.prologue(nS: nS)) else {
            try await phoneEnd.write(Self.record(BtPreauthRecord.kindReject, Data()))
            await phoneEnd.close()
            return .rejectedNoise1
        }
        try await phoneEnd.write(Self.record(BtPreauthRecord.kindNoise2, answer.message2))
        let phone = FakePairingPhone(window: .qr(secret: keys.pairKey, clientDHKey: Data()))
        lock.withLock { pairingPhone = phone }
        let channel = BluetoothChannel(stream: phoneEnd, sealKey: answer.c2, openKey: answer.c1)
        if case .paired = await phone.serve(channel) { return .paired }
        return .failed("PAIR-01 did not finish")
    }

    private static func record(_ kind: Int, _ payload: Data) -> Data {
        BtRecordCodec.encode(BtPreauthRecord.encode(kind: kind, payload: payload))
    }

    private func readRecord() async throws -> BtPreauthRecord.Decoded {
        let rlen = BtRecordCodec.decodeRlen(try await phoneEnd.read(BtRecordCodec.lengthPrefixSize))
        return try BtPreauthRecord.decode(try await phoneEnd.read(rlen))
    }
}

/// S's half of `Noise_NNpsk0_25519_ChaChaPoly_SHA256` (rev. 34), for tests only: Apple ships only the initiator
/// (`NoiseNNpsk0`, M-APP is always C), so this mirrors its steps from the responder's side with the same HLCrypto
/// primitives. Returns `nil` when `noise1`'s tag does not verify under `psk`.
enum NoiseNNpsk0Responder {
    struct Answer {
        let message2: Data
        let c1: Data
        let c2: Data
    }

    static func respond(message1: Data, psk: Data, prologue: Data) throws -> Answer? {
        let zeroNonce = Data(count: ChaCha20Poly1305.nonceByteCount)
        guard message1.count == 32 + ChaCha20Poly1305.tagByteCount else { return nil }
        let ePubC = Data(message1.prefix(32))
        let tag1 = Data(message1.suffix(ChaCha20Poly1305.tagByteCount))
        var hash = HMACSHA256.sha256(NoiseNNpsk0.protocolName)
        var ck = hash
        hash = HMACSHA256.sha256(hash + prologue)
        let pskOut = hkdf(ck, psk, outputs: 3)
        ck = pskOut[0]
        hash = HMACSHA256.sha256(hash + pskOut[1])
        hash = HMACSHA256.sha256(hash + ePubC)
        var mixed = hkdf(ck, ePubC, outputs: 2)
        ck = mixed[0]
        guard (try? ChaCha20Poly1305.open(tag1, key: mixed[1], nonce: zeroNonce, aad: hash)) != nil else { return nil }
        hash = HMACSHA256.sha256(hash + tag1)

        let ePrivS = X25519.generatePrivateKey()
        let ePubS = try X25519.publicKey(privateKey: ePrivS)
        hash = HMACSHA256.sha256(hash + ePubS)
        mixed = hkdf(ck, ePubS, outputs: 2)
        ck = mixed[0]
        mixed = hkdf(ck, try X25519.sharedSecret(privateKey: ePrivS, peerPublicKey: ePubC), outputs: 2)
        ck = mixed[0]
        let tag2 = try ChaCha20Poly1305.seal(Data(), key: mixed[1], nonce: zeroNonce, aad: hash)
        let split = hkdf(ck, Data(), outputs: 2)
        return Answer(message2: ePubS + tag2, c1: split[0], c2: split[1])
    }

    /// Noise `HKDF(ck, ikm)` with HMAC-SHA256: up to three 32-byte outputs.
    private static func hkdf(_ chainingKey: Data, _ ikm: Data, outputs: Int) -> [Data] {
        let tempKey = HMACSHA256.mac(key: chainingKey, message: ikm)
        var out: [Data] = []
        var previous = Data()
        for index in 1...outputs {
            previous = HMACSHA256.mac(key: tempKey, message: previous + Data([UInt8(index)]))
            out.append(previous)
        }
        return out
    }
}
