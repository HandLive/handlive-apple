import Foundation
import HLCrypto

/// Trạng thái khoá một chiều sau `Split()` (0.4.5 bước 4): nonce = 4 byte 0 ‖ bộ đếm 64-bit LE của chiều đó, AAD
/// rỗng; `Rekey()` tự động sau mỗi `rekeyAfterRecords` bản ghi — bộ đếm KHÔNG reset theo (Noise rev. 34 §4.2:
/// `Rekey()` chỉ đổi khoá, không đổi `n`). Không an toàn đa luồng: bên gọi tự tuần tự hoá, như `SessionCipher`
/// của phiên LAN.
public final class BtTransportCipher {
    private var key: Data
    private var counter: Int64
    private var recordsSinceRekey: Int64 = 0
    private let rekeyAfterRecords: Int64

    public init(initialKey: Data, rekeyAfterRecords: Int64 = BluetoothLinkConstants.linkRekeyRecords,
               initialCounter: Int64 = 0) {
        key = initialKey
        self.rekeyAfterRecords = rekeyAfterRecords
        counter = initialCounter
    }

    public var recordCount: Int64 { counter }

    public func seal(_ paddedPlaintext: Data) throws -> Data {
        let out = try ChaCha20Poly1305.seal(paddedPlaintext, key: key, nonce: nonce(counter), aad: Data())
        try advance()
        return out
    }

    public func open(_ ciphertextTag: Data) throws -> Data {
        let out = try ChaCha20Poly1305.open(ciphertextTag, key: key, nonce: nonce(counter), aad: Data())
        try advance()
        return out
    }

    private func advance() throws {
        counter += 1
        recordsSinceRekey += 1
        if recordsSinceRekey >= rekeyAfterRecords {
            key = try NoiseNNpsk0.rekey(key)
            recordsSinceRekey = 0
        }
    }

    private func nonce(_ counter: Int64) -> Data {
        var out = Data(count: ChaCha20Poly1305.nonceByteCount)
        let unsigned = UInt64(bitPattern: counter)
        for i in 0..<8 {
            out[4 + i] = UInt8((unsigned >> (8 * i)) & 0xFF)
        }
        return out
    }
}
