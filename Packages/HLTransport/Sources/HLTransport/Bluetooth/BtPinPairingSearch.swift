import Foundation
import HLCrypto
import HLProtocol

/// Why `BtPinPairingSearch.run` gave up without pairing and without spending a PIN attempt (PAIR-01 E3).
public enum BtPinPairingSearchError: Error, Equatable, Sendable {
    /// No phone advertising `BT_PIN_HINT` got as far as `cpace1` before `overallTimeout`.
    case timedOut
}

/// PAIR-01 flow C over Bluetooth (0.4.5 "Pairing mode" PIN, PAIR-01 C2–C4, API 12), Mac only. Scans `central` for
/// `BT_PIN_HINT`, and on each candidate's L2CAP channel runs the CPace initiator (`cpace1`/`cpace2`, M7.2a's
/// `CPaceX25519SHA512`), the link-security handshake with `K_bt_pinlink`, then the unchanged `PairingExchange` with
/// `K_bt_pin` in place of the Argon2id `K_pin` — the same pin-and-store path as the LAN. Flow B (QR) is
/// `BtQrPairingSearch`.
///
/// Wrong-PIN counting (C3, E7): every channel that fails after `cpace1` (a phone with another PIN answers `reject`
/// or fails `noise2`, an attacker answers with a low-order `Yb`) spends one of `attemptsLeft`, the counter the caller
/// shares with `PIN_INVALID` on the LAN. The search keeps trying other candidates while attempts remain, ends at once
/// with `PairingFailure.pinInvalid(attemptsLeft: 0)` on the last one (a new PIN is due), and on timeout reports what
/// is left as `pinInvalid` when any attempt was spent, so the next search starts from the right count.
public struct BtPinPairingSearch: Sendable {
    /// `BT_PIN_HINT` (0.10): advertised first by any phone with an open Bluetooth PIN window, the same for every
    /// phone, so it says nothing about the device, the PIN or a pair (AC9).
    public static let pinHint = Data(repeating: 0, count: 4)
    /// CPace channel identifier (0.4.5 "PIN").
    static let channelIdentifier = Data("HLBTPIN1".utf8)

    public let central: any BluetoothCentral
    /// PAIR-01 step 7: "Waits up to 20 s" before giving up (E3).
    public var overallTimeout: Duration = .seconds(20)
    /// CPace scalar `ya` and the Noise ephemeral key come from the system CSPRNG; the vector test fixes `ya`.
    var makeScalar: @Sendable () -> Data = { X25519.generatePrivateKey() }
    var makeEphemeral: @Sendable () -> Data = { X25519.generatePrivateKey() }

    public init(central: any BluetoothCentral) {
        self.central = central
    }

    /// `pin`: the six digits shown on this Mac. `attemptsLeft` counts this search's first attempt, as in
    /// `PairingCredential.pin` (3 for a new PIN), and seeds a fresh counter when `attempts` is `nil`. `attempts`,
    /// when given, is the counter `BluetoothFallbackPairingSearch` also hands to the LAN side for the same PIN
    /// (`PairingCredential.pin`'s `attempts`): every wrong guess here spends it directly, so attempts already
    /// spent on the other transport count too (C3). Throws `BtPinPairingSearchError.timedOut`,
    /// `PairingFailure.pinInvalid(attemptsLeft:)`, or what `PairingExchange.run` throws once a link has secured (that
    /// link holds the PIN window, 0.4.5 "Pairing link", so it is not retried on another candidate).
    public func run(identity: PairingIdentity, pin: String, attemptsLeft: Int, attempts: PinAttemptCounter? = nil,
                    offerTimeout: Duration) async throws -> PairingResult {
        let attempts = attempts ?? PinAttemptCounter(left: attemptsLeft)
        let before = await attempts.left
        do {
            return try await withThrowingTaskGroup(of: PairingResult.self) { group in
                group.addTask {
                    try await search(identity: identity, pin: pin, attempts: attempts, offerTimeout: offerTimeout)
                }
                group.addTask {
                    try await Task.sleep(for: overallTimeout)
                    throw BtPinPairingSearchError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw BtPinPairingSearchError.timedOut }
                return result
            }
        } catch BtPinPairingSearchError.timedOut {
            let left = await attempts.left
            if left < before { throw PairingFailure.pinInvalid(attemptsLeft: left) }
            throw BtPinPairingSearchError.timedOut
        }
    }

    /// `tried` is never reset: a phone that already cost an attempt is not dialed again in this search, so a
    /// bystander in PIN mode with another PIN cannot use up all three (C2: "try them one after the other").
    private func search(identity: PairingIdentity, pin: String, attempts: PinAttemptCounter,
                        offerTimeout: Duration) async throws -> PairingResult {
        var tried = Set<String>()
        for await event in central.events() {
            guard case .results(let advertisements) = event else { continue }
            for candidate in advertisements
            where !tried.contains(candidate.peripheralId) && candidate.serviceData.hints.contains(Self.pinHint) {
                tried.insert(candidate.peripheralId)
                switch await attempt(candidate: candidate, pin: pin) {
                case .notReached:
                    continue
                case .wrongPIN:
                    if await attempts.spend() <= 0 { throw PairingFailure.pinInvalid(attemptsLeft: 0) }
                case .secured(let channel, let keys):
                    let exchange = PairingExchange(identity: identity, credential: .bluetoothPIN(key: keys.pairKey),
                                                   offerTimeout: offerTimeout)
                    return try await exchange.run(over: channel, certificateSHA256: nil)
                }
            }
        }
        throw BtPinPairingSearchError.timedOut
    }

    /// Opens the candidate's channel and runs `BtPinLinkConnector`; closes the stream unless it secured. A
    /// cancelled search (the overall timeout) closes it too, so a phone that stops answering cannot hold the
    /// search past its deadline.
    private func attempt(candidate: BluetoothAdvertisement, pin: String) async -> BtPinLinkConnector.Outcome {
        guard let stream = try? await central.openChannel(peripheralId: candidate.peripheralId,
                                                          psm: candidate.serviceData.psm) else { return .notReached }
        let outcome = await withTaskCancellationHandler {
            await BtPinLinkConnector.connect(stream: stream, pin: pin, makeScalar: makeScalar,
                                             makeEphemeral: makeEphemeral)
        } onCancel: {
            Task { await stream.close() }
        }
        if case .secured = outcome { return outcome }
        await stream.close()
        return outcome
    }
}

/// The client half of one PIN pairing channel (PAIR-01 API 12): `challenge` → `cpace1` → `cpace2` → `noise1` with
/// `K_bt_pinlink` → `noise2`. Never throws: the outcome says whether the failure came before `cpace1` (no PIN attempt
/// spent) or after it (one attempt, API 12 logic 2–3). Does not close the stream.
enum BtPinLinkConnector {
    enum Outcome: @unchecked Sendable {
        /// The channel failed before `cpace1` was sent: no challenge, a malformed one, or the stream closed.
        case notReached
        /// Anything that failed after `cpace1`: `reject`, no or a malformed `cpace2`, a low-order `Yb` (all-zero `K`),
        /// a failed `noise2` tag, or the channel closing — a wrong PIN as far as either side can tell.
        case wrongPIN
        case secured(BluetoothChannel, BtPinPairingKeys)
    }

    static func connect(stream: any BluetoothByteStream, pin: String, makeScalar: () -> Data,
                        makeEphemeral: @escaping @Sendable () -> Data) async -> Outcome {
        guard let challenge = try? await BluetoothLinkConnector.readPreauthRecord(stream),
              challenge.kind == BtPreauthRecord.kindChallenge, challenge.payload.count == 32 else { return .notReached }
        let nS = Data(challenge.payload)
        let generator = CPaceX25519SHA512.calculateGenerator(prs: Data(pin.utf8),
                                                             ci: BtPinPairingSearch.channelIdentifier, sid: nS)
        let ya = makeScalar()
        guard let yaPub = CPaceX25519SHA512.scalarMultVfy(scalar: ya, point: generator),
              (try? await stream.write(record(BtPreauthRecord.kindCpace1, yaPub))) != nil else { return .notReached }

        guard let cpace2 = try? await BluetoothLinkConnector.readPreauthRecord(stream),
              cpace2.kind == BtPreauthRecord.kindCpace2, cpace2.payload.count == 32 else { return .wrongPIN }
        let ybPub = Data(cpace2.payload)
        guard let sharedK = CPaceX25519SHA512.scalarMultVfy(scalar: ya, point: ybPub) else { return .wrongPIN }
        let isk = CPaceX25519SHA512.isk(sid: nS, k: sharedK, ya: yaPub, ada: Data(), yb: ybPub, adb: Data())
        let keys = BtPinPairingKeys.derive(isk: isk, nS: nS)

        let client = BluetoothLinkSecurityClient(generateEphemeralPrivateKey: makeEphemeral)
        client.receiveChallenge(nS: nS)
        guard let noise1 = try? client.buildNoise1(psk: keys.linkKey),
              (try? await stream.write(BtRecordCodec.encode(noise1))) != nil,
              let noise2 = try? await BluetoothLinkConnector.readPreauthRecord(stream),
              noise2.kind == BtPreauthRecord.kindNoise2,
              let linkKeys = client.receiveNoise2(message2: Data(noise2.payload)) else { return .wrongPIN }
        return .secured(BluetoothChannel(stream: stream, sealKey: linkKeys.c1, openKey: linkKeys.c2), keys)
    }

    private static func record(_ kind: Int, _ payload: Data) -> Data {
        BtRecordCodec.encode(BtPreauthRecord.encode(kind: kind, payload: payload))
    }
}
