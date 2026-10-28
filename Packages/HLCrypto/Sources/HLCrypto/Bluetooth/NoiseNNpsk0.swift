import Foundation

/// `Noise_NNpsk0_25519_ChaChaPoly_SHA256` (Noise Protocol Framework rev. 34), phía C (M-APP, initiator) — bắt tay
/// bảo mật liên kết của 0.4.5 bước 1-5. Rev. 34 §9.2 (chế độ psk): mỗi token "e" làm MixHash(e.pub) RỒI
/// MixKey(e.pub), khác pattern không-psk nơi "e" chỉ MixHash — cùng thuật toán của `noise_nnpsk0.py`
/// (`handlive-shared/tools/vectors`), đã rà soát ở #3418/#3431 và kiểm chéo bằng thư viện `noiseprotocol` thật.
/// Mac luôn là C: không cần phía đáp (thử psk của từng cặp, dựng `noise2`) — đó là A7.1a (Android).
public enum NoiseNNpsk0 {
    public static let protocolName = Data("Noise_NNpsk0_25519_ChaChaPoly_SHA256".utf8)
    public static let prologueLabel = "HLBT1"

    private static let hashSize = 32
    private static let zeroNonce = Data(count: ChaCha20Poly1305.nonceByteCount)
    private static let empty = Data()

    /// prologue = `"HLBT1"` ‖ `n_s` (0.4.5 "Link-security handshake").
    public static func prologue(nS: Data) -> Data { Data(prologueLabel.utf8) + nS }

    /// `h0 = ck0` = tên giao thức, hoặc SHA-256 của nó nếu dài hơn `HASHLEN` (ở đây 37 byte > 32).
    private static func initializeSymmetric() -> (h: Data, ck: Data) {
        let h = protocolName.count <= hashSize ? protocolName : HMACSHA256.sha256(protocolName)
        return (h, h)
    }

    private static func mixHash(_ h: Data, _ data: Data) -> Data { HMACSHA256.sha256(h + data) }

    struct MixKeyResult { let ck: Data; let tempK: Data }

    /// Token DH ("ee"…) hoặc phần MixKey(e.pub) thêm của chế độ psk: 2 ngõ ra qua HMAC, KHÔNG MixHash.
    private static func mixKey(ck: Data, ikm: Data) -> MixKeyResult {
        let tempKey = HMACSHA256.mac(key: ck, message: ikm)
        let out1 = HMACSHA256.mac(key: tempKey, message: Data([0x01]))
        let out2 = HMACSHA256.mac(key: tempKey, message: out1 + Data([0x02]))
        return MixKeyResult(ck: out1, tempK: out2)
    }

    struct PskMixResult { let ck: Data; let h: Data }

    /// Token "psk": MixKeyAndHash — 3 ngõ ra qua HMAC rồi MixHash(temp_h).
    private static func mixKeyAndHashPsk(ck: Data, h: Data, psk: Data) -> PskMixResult {
        let tempKey = HMACSHA256.mac(key: ck, message: psk)
        let out1 = HMACSHA256.mac(key: tempKey, message: Data([0x01]))
        let out2 = HMACSHA256.mac(key: tempKey, message: out1 + Data([0x02]))
        return PskMixResult(ck: out1, h: mixHash(h, out2))
    }

    /// Kết quả dựng "khung đầu" (message 1) — giữ `ck1`/`h4` cần cho `tryOpenSecondMessage` (0.4.5 bước 2, 4).
    public struct FirstMessageResult: Sendable {
        let ck1: Data
        let h4: Data
        public let message1: Data
    }

    /// Phía C dựng `message1` = `e.pub` (32) ‖ ciphertext+tag (16) với psk của cặp mình đã chọn qua hint quảng
    /// bá (0.4.5 bước 2) — không thử nhiều psk như S, vì C đã biết cặp nào mình đang gọi.
    public static func firstMessage(psk: Data, prologue: Data, ephemeralPrivateKey: Data) throws -> FirstMessageResult {
        let (h0, ck0) = initializeSymmetric()
        let h1 = mixHash(h0, prologue)
        let pskStep = mixKeyAndHashPsk(ck: ck0, h: h1, psk: psk)
        let ePub = try X25519.publicKey(privateKey: ephemeralPrivateKey)
        let h3 = mixHash(pskStep.h, ePub)
        let eStep = mixKey(ck: pskStep.ck, ikm: ePub)
        let ciphertextTag = try ChaCha20Poly1305.seal(empty, key: eStep.tempK, nonce: zeroNonce, aad: h3)
        return FirstMessageResult(ck1: eStep.ck, h4: mixHash(h3, ciphertextTag), message1: ePub + ciphertextTag)
    }

    public struct SplitKeys: Equatable, Sendable {
        /// `c1` dùng để C mã hoá/S giải mã.
        public let c1: Data
        /// `c2` dùng để S mã hoá/C giải mã.
        public let c2: Data
    }

    /// Phía C mở `message2` = `e.pub` của S (32) ‖ ciphertext+tag (16) theo sau `firstMessage` (0.4.5 bước 4). Trả
    /// `nil` khi tag không khớp (bao gồm cả khi `e.pub` của S là điểm bậc thấp, `X25519.sharedSecret` ném lỗi) —
    /// 0.4.5: "C verifies its payload tag (failure → C closes the channel, CONN-05 E3)", không nói lý do cụ thể.
    public static func tryOpenSecondMessage(_ opened: FirstMessageResult, ephemeralPrivateKey: Data,
                                            message2: Data) -> SplitKeys? {
        guard message2.count == X25519KeySize + ChaCha20Poly1305.tagByteCount else { return nil }
        let ePubS = message2.prefix(X25519KeySize)
        let ciphertextTag = message2.suffix(ChaCha20Poly1305.tagByteCount)
        let h5 = mixHash(opened.h4, ePubS)
        let eStep = mixKey(ck: opened.ck1, ikm: ePubS)
        do {
            let dh = try X25519.sharedSecret(privateKey: ephemeralPrivateKey, peerPublicKey: Data(ePubS))
            let eeStep = mixKey(ck: eStep.ck, ikm: dh)
            _ = try ChaCha20Poly1305.open(Data(ciphertextTag), key: eeStep.tempK, nonce: zeroNonce, aad: h5)
            return split(eeStep.ck)
        } catch {
            return nil
        }
    }

    /// `Split()` (0.4.5 bước 4): `c1` dùng để C mã hoá/S giải mã, `c2` ngược lại.
    static func split(_ ck2: Data) -> SplitKeys {
        let tempKey = HMACSHA256.mac(key: ck2, message: empty)
        let c1 = HMACSHA256.mac(key: tempKey, message: Data([0x01]))
        let c2 = HMACSHA256.mac(key: tempKey, message: c1 + Data([0x02]))
        return SplitKeys(c1: c1, c2: c2)
    }

    /// `Rekey()` mặc định của Noise rev. 34 §4.2 (không có vector riêng của HandLive, khác mọi hàm trên — rà soát
    /// kỹ trước khi khoá theo): khoá mới = 32 byte đầu của `ENCRYPT(k, maxnonce, "", 32 byte 0)`, `maxnonce` =
    /// 2^64-1 (8 byte LE toàn `0xFF`, 4 byte đầu vẫn 0 theo cấu trúc nonce vận chuyển của 0.4.5).
    public static func rekey(_ key: Data) throws -> Data {
        let maxNonce = Data(count: 4) + Data(repeating: 0xFF, count: 8)
        let out = try ChaCha20Poly1305.seal(Data(count: 32), key: key, nonce: maxNonce, aad: empty)
        return out.prefix(32)
    }

    private static let X25519KeySize = 32
}
