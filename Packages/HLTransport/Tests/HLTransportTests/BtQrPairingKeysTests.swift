import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// `BtQrPairingKeys.derive` against `bt-pairing.json` (S7.1b, flow B only): `K_bt_pdisc`/`K_bt_plink`/`pr_bt`, then
/// that `K_bt_plink` plugs into the already-tested `BluetoothLinkSecurityClient` to build the exact `noise1` record
/// of the vector's "first_frame" entry.
@Suite("Bluetooth QR pairing keys (0.4.5 Keys, Pairing mode, flow B)")
struct BtQrPairingKeysTests {
    static func keyVector() throws -> [String: Any] {
        try #require(VectorFile("bt-pairing.json").vectors.first {
            $0["kind"] as? String == "key" && ($0["name"] as? String)?.contains("cặp 1") == true
        })
    }

    static func firstFrameVector() throws -> [String: Any] {
        try #require(VectorFile("bt-pairing.json").vectors.first { $0["kind"] as? String == "first_frame" })
    }

    @Test("K_bt_pdisc, K_bt_plink and pr_bt match the vector")
    func derivedKeysMatchVector() throws {
        let v = try Self.keyVector()
        let keys = BtQrPairingKeys.derive(pairingSecret: try v.hex("pairing_secret"))
        #expect(keys.discoveryKey == (try v.hex("k_bt_pdisc")))
        #expect(keys.linkKey == (try v.hex("k_bt_plink")))
        #expect(keys.advertisingHint == (try v.hex("pr_bt")))
    }

    @Test("K_bt_plink as the Noise psk reproduces the vector's first authenticated frame")
    func linkKeyBuildsTheVectorsFirstFrame() throws {
        let keyVector = try Self.keyVector()
        let frame = try Self.firstFrameVector()
        #expect((try frame.hex("psk")) == (try keyVector.hex("k_bt_plink")))

        let keys = BtQrPairingKeys.derive(pairingSecret: try keyVector.hex("pairing_secret"))
        let ePriv = try frame.hex("e_priv")
        let client = BluetoothLinkSecurityClient(generateEphemeralPrivateKey: { ePriv })
        client.receiveChallenge(nS: try frame.hex("n_s"))
        let preauthRecord = try client.buildNoise1(psk: keys.linkKey)
        #expect(BtRecordCodec.encode(preauthRecord) == (try frame.hex("record")))
    }

    @Test("a different pair's pairing_secret derives a different pr_bt (no cross-pair linkability, AC9)")
    func differentSecretsDeriveDifferentHints() throws {
        let first = try Self.keyVector()
        let second = try #require(VectorFile("bt-pairing.json").vectors.first {
            $0["kind"] as? String == "key" && ($0["name"] as? String)?.contains("cặp 2") == true
        })
        let keysA = BtQrPairingKeys.derive(pairingSecret: try first.hex("pairing_secret"))
        let keysB = BtQrPairingKeys.derive(pairingSecret: try second.hex("pairing_secret"))
        #expect(keysA.advertisingHint != keysB.advertisingHint)
        #expect(keysB.advertisingHint == (try second.hex("pr_bt")))
    }
}
