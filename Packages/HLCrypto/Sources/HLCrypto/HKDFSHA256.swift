import CryptoKit
import Foundation

/// HKDF-SHA256 (RFC 5869). Spec không ghi salt → salt rỗng (≡ 32 byte 0); không ghi L → L = 32 (0.6.3 bước 8).
public enum HKDFSHA256 {
    public static func extract(ikm: Data, salt: Data = Data()) -> Data {
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt)
        return Data(prk)
    }

    public static func expand(prk: Data, info: Data, length: Int) -> Data {
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: length)
        return okm.withUnsafeBytes { Data($0) }
    }

    public static func derive(ikm: Data, salt: Data = Data(), info: String, length: Int = 32) -> Data {
        expand(prk: extract(ikm: ikm, salt: salt), info: Data(info.utf8), length: length)
    }
}
