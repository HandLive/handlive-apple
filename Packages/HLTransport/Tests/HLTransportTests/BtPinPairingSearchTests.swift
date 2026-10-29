import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// `BtPinPairingSearch.run` (PAIR-01 flow C, steps C2–C4; API 12): candidates by `BT_PIN_HINT`, the CPace initiator
/// on top of `CPaceX25519SHA512` (M7.2a), the link-security handshake with `K_bt_pinlink`, the wrong-PIN counter
/// shared with the LAN (`attemptsLeft`, E7) and the hand-off to `PairingExchange` with `K_bt_pin`.
@Suite("Bluetooth PIN pairing search (PAIR-01 flow C)")
struct BtPinPairingSearchTests {
    static let pin = "482917"

    static func advertisement(_ peripheralId: String, hints: [Data] = [BtPinPairingSearch.pinHint],
                              psm: UInt16 = 23_456) -> BluetoothAdvertisement {
        BluetoothAdvertisement(peripheralId: peripheralId, serviceData: BtAdvertisementServiceData(psm: psm, hints: hints))
    }

    static func pinVector() throws -> [String: Any] {
        try #require(VectorFile("cpace.json").vectors.first { $0["kind"] as? String == "handlive_pin" })
    }

    @Test("K_bt_pinlink and K_bt_pin from ISK and n_s match every handlive_pin vector of cpace.json")
    func keysMatchVectors() throws {
        let vectors = try VectorFile("cpace.json").vectors.filter { $0["kind"] as? String == "handlive_pin" }
        #expect(vectors.count == 2)
        for vector in vectors {
            let keys = BtPinPairingKeys.derive(isk: try vector.hex("ISK"), nS: try vector.hex("n_s"))
            #expect(keys.linkKey == (try vector.hex("k_bt_pinlink")), "\(vector.label)")
            #expect(keys.pairKey == (try vector.hex("k_bt_pin")), "\(vector.label)")
        }
    }

    @Test("BT_PIN_HINT is 00 00 00 00 and a Bluetooth PIN credential says mode = pin but never matches a LAN phone")
    func credentialModeAndHint() throws {
        #expect(BtPinPairingSearch.pinHint == Data(repeating: 0, count: 4))
        let credential = PairingCredential.bluetoothPIN(key: Data(repeating: 7, count: 32))
        let exchange = PairingExchange(identity: try PairingFixtures.identity(), credential: credential,
                                       offerTimeout: .seconds(1))
        #expect(exchange.hello(nonce: Data(count: 32)).mode == .pin)
    }

    @Test("cpace1 carries the vector's Ya for its n_s and ya; the phone's cpace2 then secures the link and PAIR-01 pairs")
    func vectorTranscriptPairs() async throws {
        let vector = try Self.pinVector()
        let central = FakeBluetoothCentral()
        let phone = FakeBtPinPhone(pin: try vector.string("pin"), nS: try vector.hex("n_s"), yb: try vector.hex("yb"))
        central.onOpenChannel(peripheralId: "phone") { phone.clientEnd }
        let identity = try PairingFixtures.identity()
        let served = Task { try await phone.serveAndPair() }

        var search = BtPinPairingSearch(central: central)
        let ya = try vector.hex("ya")
        search.makeScalar = { ya }
        central.publish(.results([Self.advertisement("phone")]))
        let result = try await search.run(identity: identity, pin: try vector.string("pin"), attemptsLeft: 3,
                                          offerTimeout: .seconds(2))

        #expect(phone.receivedYa == (try vector.hex("Ya")))
        #expect(try await served.value == .paired)
        #expect(result.phoneDeviceId == phone.pairingPhone.deviceId)
    }

    @Test("no PIN-mode advertiser appears: times out (E3) without dialing anything")
    func timesOutWithNoCandidate() async throws {
        let central = FakeBluetoothCentral()
        var search = BtPinPairingSearch(central: central)
        search.overallTimeout = .milliseconds(50)
        await #expect(throws: BtPinPairingSearchError.timedOut) {
            _ = try await search.run(identity: try PairingFixtures.identity(), pin: Self.pin, attemptsLeft: 3,
                                     offerTimeout: .seconds(1))
        }
        #expect(central.openAttempts.isEmpty)
    }

    @Test("an advertiser without BT_PIN_HINT (a QR window or a pair's hint) is never dialed")
    func otherHintIsIgnored() async throws {
        let central = FakeBluetoothCentral()
        var search = BtPinPairingSearch(central: central)
        search.overallTimeout = .milliseconds(50)
        central.publish(.results([Self.advertisement("qr-phone", hints: [Data([0x5E, 0x0C, 0x9A, 0x21])])]))
        await #expect(throws: BtPinPairingSearchError.timedOut) {
            _ = try await search.run(identity: try PairingFixtures.identity(), pin: Self.pin, attemptsLeft: 3,
                                     offerTimeout: .seconds(1))
        }
        #expect(central.openAttempts.isEmpty)
    }

    @Test("a channel that fails before cpace1 (no challenge, channel closed) costs no PIN attempt")
    func preauthFailureIsNotCounted() async throws {
        let central = FakeBluetoothCentral()
        central.onOpenChannel(peripheralId: "flaky") {
            let (client, peripheral) = FakeBluetoothByteStream.pair()
            await peripheral.close()
            return client
        }
        var search = BtPinPairingSearch(central: central)
        search.overallTimeout = .milliseconds(200)
        central.publish(.results([Self.advertisement("flaky")]))
        await #expect(throws: BtPinPairingSearchError.timedOut) {
            _ = try await search.run(identity: try PairingFixtures.identity(), pin: Self.pin, attemptsLeft: 3,
                                     offerTimeout: .seconds(1))
        }
        #expect(central.openAttempts.map(\.peripheralId) == ["flaky"])
    }

    /// The phone is in PIN mode with another PIN (a typo, or someone else's phone): its `noise1` check fails and it
    /// answers `reject` (API 12 logic 3). One attempt is gone; the search keeps the count when it times out so the
    /// LAN and Bluetooth share one counter per PIN (C3).
    @Test("a phone in PIN mode with a different PIN costs one attempt, reported as pinInvalid on timeout")
    func phoneWithDifferentPinCostsOneAttempt() async throws {
        let central = FakeBluetoothCentral()
        let phone = FakeBtPinPhone(pin: "482918")
        central.onOpenChannel(peripheralId: "other-pin") { phone.clientEnd }
        let served = Task { try await phone.serveAndPair() }

        var search = BtPinPairingSearch(central: central)
        search.overallTimeout = .milliseconds(500)
        central.publish(.results([Self.advertisement("other-pin")]))
        await #expect(throws: PairingFailure.pinInvalid(attemptsLeft: 2)) {
            _ = try await search.run(identity: try PairingFixtures.identity(), pin: Self.pin, attemptsLeft: 3,
                                     offerTimeout: .seconds(1))
        }
        #expect(try await served.value == .rejectedNoise1)
    }

    @Test("the last attempt on a wrong PIN ends the search at once with pinInvalid(0): a new PIN is due (E7)")
    func lastAttemptEndsSearch() async throws {
        let central = FakeBluetoothCentral()
        let phone = FakeBtPinPhone(pin: "000000")
        central.onOpenChannel(peripheralId: "wrong") { phone.clientEnd }
        Task { _ = try? await phone.serveAndPair() }

        var search = BtPinPairingSearch(central: central)
        search.overallTimeout = .seconds(10)
        central.publish(.results([Self.advertisement("wrong")]))
        let started = ContinuousClock.now
        await #expect(throws: PairingFailure.pinInvalid(attemptsLeft: 0)) {
            _ = try await search.run(identity: try PairingFixtures.identity(), pin: Self.pin, attemptsLeft: 1,
                                     offerTimeout: .seconds(1))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("three phones with other PINs use up all three attempts across candidates, never a fourth channel")
    func threeWrongPhonesExhaustTheCounter() async throws {
        let central = FakeBluetoothCentral()
        var phones: [FakeBtPinPhone] = []
        for (index, otherPin) in ["111111", "222222", "333333", "444444"].enumerated() {
            let phone = FakeBtPinPhone(pin: otherPin)
            phones.append(phone)
            central.onOpenChannel(peripheralId: "p\(index)") { phone.clientEnd }
            Task { _ = try? await phone.serveAndPair() }
        }
        var search = BtPinPairingSearch(central: central)
        search.overallTimeout = .seconds(10)
        central.publish(.results((0..<4).map { Self.advertisement("p\($0)") }))
        await #expect(throws: PairingFailure.pinInvalid(attemptsLeft: 0)) {
            _ = try await search.run(identity: try PairingFixtures.identity(), pin: Self.pin, attemptsLeft: 3,
                                     offerTimeout: .seconds(1))
        }
        #expect(central.openAttempts.count == 3)
    }

    /// An attacker answering `cpace1` with a low-order `Yb` (all-zero `K`): the Mac closes without answering and
    /// counts it as one failed attempt (API 12 logic 2), then moves on to the real phone, which pairs.
    @Test("an attacker answering cpace1 with a low-order Yb costs one attempt; the real phone still pairs")
    func attackerAnsweringCpace1IsSkipped() async throws {
        let central = FakeBluetoothCentral()
        let attacker = FakeBtPinPhone(pin: Self.pin, behavior: .lowOrderCpace2)
        let phone = FakeBtPinPhone(pin: Self.pin)
        central.onOpenChannel(peripheralId: "attacker") { attacker.clientEnd }
        central.onOpenChannel(peripheralId: "phone") { phone.clientEnd }
        let attacked = Task { try await attacker.serveAndPair() }
        let served = Task { try await phone.serveAndPair() }

        let search = BtPinPairingSearch(central: central)
        central.publish(.results([Self.advertisement("attacker")]))
        central.publish(.results([Self.advertisement("attacker"), Self.advertisement("phone")]))
        let result = try await search.run(identity: try PairingFixtures.identity(), pin: Self.pin, attemptsLeft: 3,
                                          offerTimeout: .seconds(2))

        #expect(try await attacked.value == .closedAfterCpace2)
        #expect(try await served.value == .paired)
        #expect(result.phoneDeviceId == phone.pairingPhone.deviceId)
        #expect(central.openAttempts.map(\.peripheralId) == ["attacker", "phone"])
    }

    @Test("an attacker answering cpace1 and nothing more: one attempt gone when the search times out")
    func attackerOnlyCostsOneAttempt() async throws {
        let central = FakeBluetoothCentral()
        let attacker = FakeBtPinPhone(pin: Self.pin, behavior: .lowOrderCpace2)
        central.onOpenChannel(peripheralId: "attacker") { attacker.clientEnd }
        Task { _ = try? await attacker.serveAndPair() }
        var search = BtPinPairingSearch(central: central)
        search.overallTimeout = .milliseconds(500)
        central.publish(.results([Self.advertisement("attacker")]))
        await #expect(throws: PairingFailure.pinInvalid(attemptsLeft: 2)) {
            _ = try await search.run(identity: try PairingFixtures.identity(), pin: Self.pin, attemptsLeft: 3,
                                     offerTimeout: .seconds(1))
        }
    }
}
