import Foundation
import HLCrypto
import HLProtocol

/// Phía C (M-APP) của bắt tay bảo mật liên kết cho MỘT kênh (0.4.5 "Link-security handshake" bước 1-4): C đã
/// biết cặp mình đang gọi qua hint quảng bá, nên dựng `noise1` thẳng với psk của cặp đó — khác S (A7.1a), không
/// thử nhiều psk. Không tự đóng kênh: bên gọi (M7.1c) làm việc đó theo kết quả trả về.
public final class BluetoothLinkSecurityClient {
    private var prologue: Data!
    private var opened: NoiseNNpsk0.FirstMessageResult?
    private var ephemeralPrivateKey: Data?
    private let generateEphemeralPrivateKey: () -> Data

    public init(generateEphemeralPrivateKey: @escaping () -> Data = { X25519.generatePrivateKey() }) {
        self.generateEphemeralPrivateKey = generateEphemeralPrivateKey
    }

    /// Bước 1: `nS` = thân `challenge` sau byte kind, dựng prologue trói buộc vào kênh này.
    public func receiveChallenge(nS: Data) {
        prologue = NoiseNNpsk0.prologue(nS: nS)
    }

    /// Bước 2: dựng `noise1` với psk của cặp mình đang gọi (C đã biết cặp qua hint quảng bá, không thử nhiều psk
    /// như S).
    public func buildNoise1(psk: Data) throws -> Data {
        let ephemeral = generateEphemeralPrivateKey()
        let built = try NoiseNNpsk0.firstMessage(psk: psk, prologue: prologue, ephemeralPrivateKey: ephemeral)
        ephemeralPrivateKey = ephemeral
        opened = built
        return BtPreauthRecord.encode(kind: BtPreauthRecord.kindNoise1, payload: built.message1)
    }

    public struct LinkKeys: Equatable, Sendable {
        public let c1: Data
        public let c2: Data
    }

    /// Bước 4: `message2` = thân `noise2` sau byte kind; trả khoá `Split()` khi tag khớp, `nil` khi xác thực khoá
    /// thất bại (bao gồm `e.pub` của S là điểm bậc thấp) — 0.4.5 bước 4: C đóng kênh ngay, không nói lý do.
    public func receiveNoise2(message2: Data) -> LinkKeys? {
        guard let opened, let ephemeralPrivateKey else { preconditionFailure("noise1 chưa dựng") }
        guard let keys = NoiseNNpsk0.tryOpenSecondMessage(opened, ephemeralPrivateKey: ephemeralPrivateKey,
                                                           message2: message2) else { return nil }
        return LinkKeys(c1: keys.c1, c2: keys.c2)
    }
}
