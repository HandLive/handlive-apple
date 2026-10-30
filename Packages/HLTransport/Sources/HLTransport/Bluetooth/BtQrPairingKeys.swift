import Foundation
import HLCrypto
import HLProtocol

/// Bluetooth keys for one QR code, flow B of PAIR-01 only (0.4.5 "Keys", "Pairing mode"): derived from
/// `pairing_secret` the moment the window opens, held only in memory for `PAIRING_WINDOW`, never persisted. Flow C
/// (the PIN) derives its own Bluetooth keys from a CPace `ISK` instead — out of scope here (`#218`).
public struct BtQrPairingKeys: Sendable, Equatable {
    /// `K_bt_pdisc` = HKDF-SHA256(ikm = `pairing_secret`, salt = empty, info = "handlive/v1/bt-pair-disc", L = 32).
    public let discoveryKey: Data
    /// `K_bt_plink` = HKDF-SHA256(ikm = `pairing_secret`, salt = empty, info = "handlive/v1/bt-pair-link", L = 32);
    /// the Noise psk of the pairing link (0.4.5 "Link-security handshake").
    public let linkKey: Data
    /// `pr_bt` = the first 4 bytes of HMAC-SHA256(`K_bt_pdisc`, "HLBTPAIR1"): the advertising hint the Mac scans
    /// for and A-SVC puts first in its scan response while this QR's window is open.
    public let advertisingHint: Data

    static let discoveryInfo = "handlive/v1/bt-pair-disc"
    static let linkInfo = "handlive/v1/bt-pair-link"
    static let hintLabel = Data("HLBTPAIR1".utf8)

    public static func derive(pairingSecret: Data) -> BtQrPairingKeys {
        let discoveryKey = HKDFSHA256.derive(ikm: pairingSecret, info: discoveryInfo)
        let linkKey = HKDFSHA256.derive(ikm: pairingSecret, info: linkInfo)
        let hint = HMACSHA256.mac(key: discoveryKey, message: hintLabel).prefix(BtAdvertisementServiceData.hintSize)
        return BtQrPairingKeys(discoveryKey: discoveryKey, linkKey: linkKey, advertisingHint: Data(hint))
    }
}
