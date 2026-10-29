import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// M7.1c: `ConnectionManager` driving a real connect attempt over Bluetooth, through a fake central and an
/// in-memory L2CAP byte pipe (no radio) — `CoreBluetoothCentral`/`CoreBluetoothL2CAPStream` themselves are
/// **not measured here**, only on a real Mac + phone (Gói B, chưa đo trên máy).
@Suite("Connection manager over Bluetooth, fake central (M7.1c)")
struct ConnectionManagerBluetoothConnectTests {
    /// Everything `bt-link.json`'s "cặp 1" handshake vector gives, keyed to a `PairContext` whose `prk` is the
    /// vector's own — so `BtLinkKeyDerivation.kBtLink(prk:)` on the client side reproduces the vector's `psk`.
    struct Handshake {
        let pair: PairContext
        let ePrivC: Data
        let challengeRecord: Data
        let noise2Record: Data
        let c1: Data
        let c2: Data
    }

    static func handshakeVector() throws -> Handshake {
        let file = try VectorFile("bt-link.json")
        let keyVector = try #require(file.vectors.first {
            $0["kind"] as? String == "key" && ($0["name"] as? String)?.contains("cặp 1") == true
        })
        let handshake = try #require(file.vectors.first {
            $0["kind"] as? String == "handshake" && ($0["name"] as? String)?.contains("cặp 1") == true
        })
        let base = SessionHarness.pair()
        let pair = PairContext(pairId: base.pairId, clientDeviceId: base.clientDeviceId,
                               serverDeviceId: base.serverDeviceId, prk: try keyVector.hex("prk"))
        return Handshake(pair: pair, ePrivC: try handshake.hex("e_priv_c"),
                         challengeRecord: try handshake.hex("challenge_record"),
                         noise2Record: try handshake.hex("noise2_record"), c1: try handshake.hex("c1"),
                         c2: try handshake.hex("c2"))
    }

    /// Hint of the current epoch for `prk` (0.4.5 "Advertisement") — computed fresh, like
    /// `DiscoveryHint.acceptedHints` already is for the LAN fakes in `ManagerHarness`, since the vector's own
    /// epochs are frozen in the past.
    static func currentHint(prk: Data) -> Data {
        let discoveryKey = BtLinkKeyDerivation.kBtDisc(prk: prk)
        return BtAdvertisementHint.hint(discoveryKey: discoveryKey, epoch: BtAdvertisementHint.epochIndex(
            nowMs: HLUUID.currentTimeMs()))
    }

    /// Wires a fake peripheral at `peripheralId` that completes the handshake with `noise2Record` and, on
    /// success, runs `FakePhone`'s session handshake on top — the "good" candidate of a scenario.
    static func wireWorkingPeripheral(_ setup: ManagerHarness.Setup, peripheralId: String, _ v: Handshake) {
        let (client, peripheral) = FakeBluetoothByteStream.pair()
        setup.bluetooth.onOpenChannel(peripheralId: peripheralId) { client }
        let fake = FakeBluetoothPeripheral(stream: peripheral, challengeRecord: v.challengeRecord,
                                           noise2Record: v.noise2Record, sealKey: v.c2, openKey: v.c1)
        Task {
            guard let channel = try? await fake.runHandshake() else { return }
            _ = try? await FakePhone(channel: channel, pair: v.pair).accept()
        }
    }

    @Test("A matching hint over Bluetooth connects (CONN-05 steps 3–9)")
    func hintMatchConnects() async throws {
        let v = try Self.handshakeVector()
        let setup = await ManagerHarness.make(pair: v.pair)
        await setup.manager.setBluetoothEphemeralKey { v.ePrivC }
        Self.wireWorkingPeripheral(setup, peripheralId: "peripheral-1", v)

        setup.bluetooth.publish(.poweredOn)
        setup.bluetooth.publish(.results([BluetoothAdvertisement(
            peripheralId: "peripheral-1",
            serviceData: BtAdvertisementServiceData(psm: 23456, hints: [Self.currentHint(prk: v.pair.prk)]))]))

        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.bluetooth)) != nil)
        await setup.manager.stop()
    }

    @Test("The connector always opens the latest advertised PSM, never a cached one (rotation)")
    func rotatedPsmUsesTheLatestValue() async throws {
        let v = try Self.handshakeVector()
        let setup = await ManagerHarness.make(pair: v.pair)
        await setup.manager.setBluetoothEphemeralKey { v.ePrivC }
        Self.wireWorkingPeripheral(setup, peripheralId: "peripheral-1", v)

        let hint = Self.currentHint(prk: v.pair.prk)
        setup.bluetooth.publish(.poweredOn)
        setup.bluetooth.publish(.results([BluetoothAdvertisement(
            peripheralId: "peripheral-1", serviceData: BtAdvertisementServiceData(psm: 11111, hints: [hint]))]))
        // Rotates (0.4.5 "Rotation": new PSM, new advertising set, same `BT_HINT_PERIOD`) before the manager
        // ever looks: only the latest snapshot must ever reach `openChannel`.
        setup.bluetooth.publish(.results([BluetoothAdvertisement(
            peripheralId: "peripheral-1", serviceData: BtAdvertisementServiceData(psm: 22222, hints: [hint]))]))

        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.bluetooth)) != nil)
        #expect(setup.bluetooth.openAttempts.map(\.psm) == [22_222])
        await setup.manager.stop()
    }

    @Test("A tampered noise2 tries the next candidate before backing off (CONN-05 E3)")
    func nextCandidateAfterNoise2Failure() async throws {
        let v = try Self.handshakeVector()
        let setup = await ManagerHarness.make(pair: v.pair)
        await setup.manager.setBluetoothEphemeralKey { v.ePrivC }
        let hint = Self.currentHint(prk: v.pair.prk)
        setup.bluetooth.publish(.poweredOn)
        setup.bluetooth.publish(.results([
            BluetoothAdvertisement(peripheralId: "bad", serviceData: BtAdvertisementServiceData(psm: 1, hints: [hint])),
            BluetoothAdvertisement(peripheralId: "good", serviceData: BtAdvertisementServiceData(psm: 2, hints: [hint])),
        ]))

        let invalid = try #require(VectorFile("bt-link.json").invalidVectors.first {
            $0["reason"] as? String == "tag_mismatch_noise2"
        })
        let tamperedPayload = try invalid.hex("e_pub_s") + invalid.hex("ciphertext_tag_2")
        let tamperedNoise2 = BtRecordCodec.encode(BtPreauthRecord.encode(kind: BtPreauthRecord.kindNoise2,
                                                                          payload: tamperedPayload))
        let (badClient, badPeripheral) = FakeBluetoothByteStream.pair()
        setup.bluetooth.onOpenChannel(peripheralId: "bad") { badClient }
        let badFake = FakeBluetoothPeripheral(stream: badPeripheral, challengeRecord: v.challengeRecord,
                                              noise2Record: tamperedNoise2, sealKey: v.c2, openKey: v.c1)
        Task { _ = try? await badFake.runHandshake() }

        Self.wireWorkingPeripheral(setup, peripheralId: "good", v)

        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.bluetooth)) != nil)
        #expect(Set(setup.bluetooth.openAttempts.map(\.peripheralId)) == ["bad", "good"])
        await setup.manager.stop()
    }

    @Test("No matching peer ever appears: no connect attempt, ordinary backoff on the LAN_DISCOVERY_GRACE schedule (CONN-05 E2)")
    func noPeerSeenNeverAttemptsAConnection() async throws {
        let v = try Self.handshakeVector()
        let setup = await ManagerHarness.make(pair: v.pair)
        setup.bluetooth.publish(.poweredOn) // no .results ever follows: the phone is out of range, or A-SVC stopped

        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.backoff) != nil)
        #expect(setup.bluetooth.openAttempts.isEmpty)
        await setup.manager.stop()
    }

    @Test("Bluetooth turning off clears discovered advertisements; turning back on needs a fresh one (0.4.5 E1)")
    func poweredOffThenOnClearsStaleAdvertisements() async throws {
        let v = try Self.handshakeVector()
        let setup = await ManagerHarness.make(pair: v.pair)
        let hint = Self.currentHint(prk: v.pair.prk)
        Self.wireWorkingPeripheral(setup, peripheralId: "peripheral-1", v)
        setup.bluetooth.publish(.poweredOn)
        setup.bluetooth.publish(.results([BluetoothAdvertisement(
            peripheralId: "peripheral-1",
            serviceData: BtAdvertisementServiceData(psm: 23456, hints: [hint]))]))

        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.bluetooth)) != nil)
        #expect(await !setup.manager.matchingBluetoothCandidates().isEmpty)

        setup.bluetooth.publish(.poweredOff)
        #expect(await waitUntil { await setup.manager.matchingBluetoothCandidates().isEmpty })
        // The radio turning off is a scanning concern, not a reason to drop an already-open L2CAP session.
        #expect(await setup.recorder.waitForState(.connected(.bluetooth)) != nil)

        setup.bluetooth.publish(.poweredOn) // no fresh advertisement republished yet
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await setup.manager.matchingBluetoothCandidates().isEmpty) // the stale entry must not come back on its own

        await setup.manager.stop()
    }

    @Test("A dropped Bluetooth link ends the session and backs off (CONN-05 E6)")
    func disconnectBacksOff() async throws {
        let v = try Self.handshakeVector()
        let setup = await ManagerHarness.make(pair: v.pair)
        await setup.manager.setBluetoothEphemeralKey { v.ePrivC }

        let (client, peripheral) = FakeBluetoothByteStream.pair()
        setup.bluetooth.onOpenChannel(peripheralId: "peripheral-1") { client }
        let fake = FakeBluetoothPeripheral(stream: peripheral, challengeRecord: v.challengeRecord,
                                           noise2Record: v.noise2Record, sealKey: v.c2, openKey: v.c1)
        Task {
            guard let channel = try? await fake.runHandshake() else { return }
            _ = try? await FakePhone(channel: channel, pair: v.pair).accept()
        }
        setup.bluetooth.publish(.poweredOn)
        setup.bluetooth.publish(.results([BluetoothAdvertisement(
            peripheralId: "peripheral-1",
            serviceData: BtAdvertisementServiceData(psm: 23456, hints: [Self.currentHint(prk: v.pair.prk)]))]))

        await setup.manager.start(phone: setup.phone)
        #expect(await setup.recorder.waitForState(.connected(.bluetooth)) != nil)

        await peripheral.close() // `didDisconnectPeripheral`-equivalent: the other end goes away mid-session

        #expect(await setup.recorder.waitForState(.backoff) != nil)
        await setup.manager.stop()
    }
}
