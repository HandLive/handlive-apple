import Foundation
import HLCrypto

/// Bluetooth keys of one PIN pairing channel, flow C of PAIR-01 (0.4.5 "Keys from ISK", PAIR-01 API 12): derived
/// from the CPace `ISK` of that channel with `n_s` as the salt, held only in memory and dropped with the PIN.
public struct BtPinPairingKeys: Sendable, Equatable {
    /// `K_bt_pinlink` = HKDF-SHA256(ikm = `ISK`, salt = `n_s`, info = "handlive/v1/bt-pin-link", L = 32): the Noise
    /// psk of the PIN pairing link (prologue `"HLBT1"` ‖ `n_s`, as for any link).
    public let linkKey: Data
    /// `K_bt_pin` = HKDF-SHA256(ikm = `ISK`, salt = `n_s`, info = "handlive/v1/bt-pin-pair", L = 32): replaces the
    /// Argon2id `K_pin` in PAIR-01 steps 9–11 (0.6.2).
    public let pairKey: Data

    static let linkInfo = "handlive/v1/bt-pin-link"
    static let pairInfo = "handlive/v1/bt-pin-pair"

    public static func derive(isk: Data, nS: Data) -> BtPinPairingKeys {
        BtPinPairingKeys(linkKey: HKDFSHA256.derive(ikm: isk, salt: nS, info: linkInfo),
                         pairKey: HKDFSHA256.derive(ikm: isk, salt: nS, info: pairInfo))
    }
}
