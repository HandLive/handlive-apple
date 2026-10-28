import Foundation

/// `K_bt_disc`/`K_bt_link` (0.4.5): HKDF-SHA256(`PRK`, salt rỗng, info, L = 32) — sống suốt đời cặp, tính khi cần
/// như `K_push`. Khác `K_bt_pdisc`/`K_bt_plink` (dẫn từ `pairing_secret`, chỉ sống theo một QR).
public enum BtLinkKeyDerivation {
    public static let discoveryInfo = "handlive/v1/bt-discovery"
    public static let linkInfo = "handlive/v1/bt-link"

    public static func kBtDisc(prk: Data) -> Data { HKDFSHA256.derive(ikm: prk, info: discoveryInfo, length: 32) }

    public static func kBtLink(prk: Data) -> Data { HKDFSHA256.derive(ikm: prk, info: linkInfo, length: 32) }
}
