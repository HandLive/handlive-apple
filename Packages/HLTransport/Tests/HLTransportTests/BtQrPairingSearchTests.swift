import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// `BtQrPairingSearch.run` (PAIR-01 flow B, steps B1–B4): candidate matching by `pr_bt`, retry on a pre-auth
/// failure, the overall timeout of step 7, and the hand-off to `PairingExchange` once a channel secures.
@Suite("Bluetooth QR pairing search (PAIR-01 flow B)")
struct BtQrPairingSearchTests {
    static let pairingSecret = PairingCodes.newPairingSecret()
    static let keys = BtQrPairingKeys.derive(pairingSecret: pairingSecret)

    static func advertisement(peripheralId: String, hints: [Data], psm: UInt16 = 23_456) -> BluetoothAdvertisement {
        BluetoothAdvertisement(peripheralId: peripheralId,
                               serviceData: BtAdvertisementServiceData(psm: psm, hints: hints))
    }

    @Test("no advertiser ever appears: times out instead of hanging")
    func timesOutWithNoCandidate() async throws {
        let central = FakeBluetoothCentral()
        var search = BtQrPairingSearch(central: central)
        search.overallTimeout = .milliseconds(50)
        let identity = try PairingFixtures.identity()
        await #expect(throws: BtQrPairingSearchError.timedOut) {
            _ = try await search.run(identity: identity, pairingSecret: Self.pairingSecret, offerTimeout: .seconds(1))
        }
        #expect(central.openAttempts.isEmpty)
    }

    @Test("an advertiser with the wrong pr_bt is never dialed (0.4.5: no matching hint is ignored)")
    func wrongHintIsIgnored() async throws {
        let central = FakeBluetoothCentral()
        var search = BtQrPairingSearch(central: central)
        search.overallTimeout = .milliseconds(50)
        let identity = try PairingFixtures.identity()
        central.publish(.poweredOn)
        central.publish(.results([Self.advertisement(peripheralId: "stranger", hints: [Data(repeating: 0x99, count: 4)])]))

        await #expect(throws: BtQrPairingSearchError.timedOut) {
            _ = try await search.run(identity: identity, pairingSecret: Self.pairingSecret, offerTimeout: .seconds(1))
        }
        #expect(central.openAttempts.isEmpty)
    }

    /// A device advertising the right `pr_bt` (a copied advertisement, or simply not this phone) but unable to
    /// complete the link-security handshake: tried once, then the search times out since no other candidate
    /// appears (0.4.5 "Several advertisers... are tried one after the other", E11).
    @Test("a device advertising the right pr_bt but failing the handshake does not pair")
    func spoofedAdvertiserFailsHandshake() async throws {
        let file = try VectorFile("bt-link.json")
        let handshake = try #require(file.vectors.first {
            $0["kind"] as? String == "handshake" && ($0["name"] as? String)?.contains("cặp 1") == true
        })
        let invalid = try #require(file.invalidVectors.first { $0["reason"] as? String == "tag_mismatch_noise2" })
        let tamperedPayload = try invalid.hex("e_pub_s") + invalid.hex("ciphertext_tag_2")
        let tamperedNoise2 = BtRecordCodec.encode(BtPreauthRecord.encode(kind: BtPreauthRecord.kindNoise2,
                                                                          payload: tamperedPayload))

        let central = FakeBluetoothCentral()
        let (client, peripheral) = FakeBluetoothByteStream.pair()
        central.onOpenChannel(peripheralId: "fake") { client }
        let fake = FakeBluetoothPeripheral(stream: peripheral, challengeRecord: try handshake.hex("challenge_record"),
                                           noise2Record: tamperedNoise2, sealKey: Data(), openKey: Data())
        Task { _ = try? await fake.runHandshake() }

        var search = BtQrPairingSearch(central: central)
        search.overallTimeout = .milliseconds(200)
        let identity = try PairingFixtures.identity()
        central.publish(.poweredOn)
        central.publish(.results([Self.advertisement(peripheralId: "fake", hints: [Self.keys.advertisingHint])]))

        await #expect(throws: BtQrPairingSearchError.timedOut) {
            _ = try await search.run(identity: identity, pairingSecret: Self.pairingSecret, offerTimeout: .seconds(1))
        }
        #expect(central.openAttempts.map(\.peripheralId) == ["fake"])
    }

    /// Once `connectLink` hands back a secured channel, `PairingExchange` runs on it exactly as on the LAN: a
    /// `FakePairingPhone` on the other end completes PAIR-01 and the search returns its `PairingResult`. The real
    /// Noise round trip is already covered by `BluetoothLinkConnectorTests` and `BtQrPairingKeysTests`, so this
    /// test substitutes `connectLink` to isolate the scan/candidate/hand-off logic this file adds.
    @Test("a matching candidate whose link secures completes PAIR-01 and returns the pair")
    func matchingCandidateCompletesPairing() async throws {
        let central = FakeBluetoothCentral()
        let (client, phoneEnd) = FakeBluetoothByteStream.pair()
        central.onOpenChannel(peripheralId: "phone-1") { client }

        let identity = try PairingFixtures.identity()
        let sealKey = Data(repeating: 0x11, count: 32)
        let openKey = Data(repeating: 0x22, count: 32)
        let phone = FakePairingPhone(window: .qr(secret: Self.pairingSecret, clientDHKey: identity.dhPublicKey))
        Task {
            let phoneChannel = BluetoothChannel(stream: phoneEnd, sealKey: openKey, openKey: sealKey)
            _ = await phone.serve(phoneChannel)
        }

        var search = BtQrPairingSearch(central: central)
        search.connectLink = { stream, _ in BluetoothChannel(stream: stream, sealKey: sealKey, openKey: openKey) }
        central.publish(.poweredOn)
        central.publish(.results([Self.advertisement(peripheralId: "phone-1", hints: [Self.keys.advertisingHint])]))

        let result = try await search.run(identity: identity, pairingSecret: Self.pairingSecret, offerTimeout: .seconds(2))
        #expect(result.phoneDeviceId == phone.deviceId)
        #expect(central.openAttempts.map(\.peripheralId) == ["phone-1"])
    }
}
