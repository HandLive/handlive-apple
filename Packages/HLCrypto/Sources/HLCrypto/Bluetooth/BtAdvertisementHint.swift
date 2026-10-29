import Foundation

/// BLE advertisement hints (0.4.5 "Advertisement"), parallel to `DiscoveryHint` for mDNS but with the Bluetooth
/// period and label: hint = the first 4 bytes of HMAC-SHA256(`K_bt_disc`, `"HLBTDISC1"` ‖ int64 BE `epoch`),
/// `epoch` = `floor(now_ms / BT_HINT_PERIOD)`. The client accepts the epochs from `e − 4` to `e + 4` (0.4.5
/// "Advertisement": clock skew up to an hour, as on the LAN, since `BT_HINT_PERIOD` is 15 minutes).
public enum BtAdvertisementHint {
    public static let label = Data("HLBTDISC1".utf8)
    public static let periodMilliseconds: Int64 = 900_000
    public static let epochWindow: Int64 = 4

    /// Hint of one epoch (`floor(now_ms / BT_HINT_PERIOD)`), raw 4 bytes as carried in the scan response.
    public static func hint(discoveryKey: Data, epoch: Int64) -> Data {
        var message = label
        withUnsafeBytes(of: epoch.bigEndian) { message.append(contentsOf: $0) }
        return HMACSHA256.mac(key: discoveryKey, message: message).prefix(4)
    }

    /// `floor(now_ms / BT_HINT_PERIOD)`, rounding down for negative clocks too.
    public static func epochIndex(nowMs: Int64) -> Int64 {
        nowMs >= 0 ? nowMs / periodMilliseconds : (nowMs - periodMilliseconds + 1) / periodMilliseconds
    }

    /// Hints a client accepts at `nowMs`: the epochs from `e − 4` to `e + 4` (9 total).
    public static func acceptedHints(prk: Data, nowMs: Int64) -> [Data] {
        let discoveryKey = BtLinkKeyDerivation.kBtDisc(prk: prk)
        let epoch = epochIndex(nowMs: nowMs)
        return (epoch - epochWindow...epoch + epochWindow).map { hint(discoveryKey: discoveryKey, epoch: $0) }
    }

    /// Whether any of `advertised` hints (a scan response may carry several, one per pair) is accepted.
    public static func matches(advertised: [Data], accepted: [Data]) -> Bool {
        advertised.contains { accepted.contains($0) }
    }
}
