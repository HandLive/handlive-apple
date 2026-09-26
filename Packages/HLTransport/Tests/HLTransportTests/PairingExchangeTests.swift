import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// PAIR-01 steps 9–11 and A4–A5 against a phone written from the spec.
@Suite("Pairing exchange on /v1/pair (PAIR-01 API 2–6)")
struct PairingExchangeTests {
    static let authFailed = PairErrorData(code: .authFailed, message: "Pairing authentication failed")
    let identity: PairingIdentity
    let secret = PairingCodes.newPairingSecret()

    init() throws {
        identity = try PairingFixtures.identity()
    }

    struct Run {
        let result: Result<PairingResult, PairingFailure>
        let outcome: FakePairingPhone.Outcome
        let closeCode: CloseCode?
    }

    func run(_ phone: FakePairingPhone, credential: PairingCredential? = nil, certificate: Data? = nil,
             offerTimeout: Duration = .seconds(5)) async -> Run {
        let (client, phoneEnd) = InMemoryChannel.pair()
        var exchange = PairingExchange(identity: identity, credential: credential ?? .qr(secret: secret),
                                       offerTimeout: offerTimeout)
        exchange.pinParameters = PairingFixtures.smallPIN
        let served = Task { await phone.serve(phoneEnd) }
        let result: Result<PairingResult, PairingFailure>
        do {
            result = .success(try await exchange.run(over: client, certificateSHA256: certificate ?? phone.tlsSHA256))
        } catch let failure as PairingFailure {
            result = .failure(failure)
        } catch {
            result = .failure(.disconnected)
        }
        return Run(result: result, outcome: await served.value, closeCode: phoneEnd.receivedCloseCode)
    }

    func qrPhone(_ fault: FakePairingPhone.Fault = .none) -> FakePairingPhone {
        FakePairingPhone(window: .qr(secret: secret, clientDHKey: identity.dhPublicKey), fault: fault)
    }

    @Test("QR: both sides end with the same pair_id, PRK and a doubly signed attestation; closed with 1000")
    func pairsWithQRCode() async throws {
        let phone = qrPhone()
        let run = await run(phone)
        let paired = try run.result.get()
        #expect(run.outcome == .paired(pairId: paired.pairId, prk: paired.prk))
        #expect(HLUUID.isValid(paired.pairId, version: 4))
        #expect(paired.phoneDeviceId == phone.deviceId && paired.phoneName == "Pixel của Lan")
        #expect(paired.phoneModel == "Pixel 8" && paired.phoneOSVersion == "15")
        #expect(paired.certificateSHA256 == phone.tlsSHA256)
        #expect(Ed25519.verify(paired.signatureSelf, message: paired.attestation, publicKey: identity.signingPublicKey))
        #expect(Ed25519.verify(paired.signaturePeer, message: paired.attestation, publicKey: phone.signingPublicKey))
        #expect(run.closeCode == .normal)
    }

    @Test("E4: a wrong offer MAC, device_id or TLS binding → pair/error AUTH_FAILED, nothing kept")
    func refusesBadOffers() async {
        for fault in [FakePairingPhone.Fault.wrongOfferMac, .wrongDeviceId] {
            let run = await run(qrPhone(fault))
            #expect(run.result == .failure(.authFailed))
            #expect(run.outcome == .clientRefused(Self.authFailed))
        }
        let run = await run(qrPhone(), certificate: Data(repeating: 0xCD, count: 32))
        #expect(run.result == .failure(.authFailed))
        #expect(run.outcome == .clientRefused(Self.authFailed))
    }

    @Test("E4 after pair/done: a wrong signature, prk_check or MAC is refused")
    func refusesBadDone() async {
        for fault in [FakePairingPhone.Fault.wrongDoneSignature, .wrongDonePrkCheck, .wrongDoneMac] {
            let run = await run(qrPhone(fault))
            #expect(run.result == .failure(.authFailed))
            #expect(run.outcome == .clientRefused(Self.authFailed))
        }
    }

    @Test("A QR code whose secret the phone does not have fails as AUTH_FAILED, not as a PIN error")
    func wrongSecret() async {
        let phone = FakePairingPhone(window: .qr(secret: PairingCodes.newPairingSecret(), clientDHKey: identity.dhPublicKey))
        #expect(await run(phone).result == .failure(.authFailed))
    }

    @Test("PIN: the typed PIN pairs; a wrong one is PIN_INVALID with the attempts left (E7)")
    func pin() async throws {
        let paired = await run(FakePairingPhone(window: .pin("042917")), credential: .pin("042917", attemptsLeft: 3))
        let result = try paired.result.get()
        #expect(paired.outcome == .paired(pairId: result.pairId, prk: result.prk))
        let wrong = await run(FakePairingPhone(window: .pin("042918")), credential: .pin("042917", attemptsLeft: 3))
        #expect(wrong.result == .failure(.pinInvalid(attemptsLeft: 2)))
        #expect(wrong.outcome == .clientRefused(PairErrorData(code: .pinInvalid, message: "PIN does not match",
                                                               attemptsLeft: 2)))
        let last = await run(FakePairingPhone(window: .pin("111111")), credential: .pin("042917", attemptsLeft: 1))
        #expect(last.result == .failure(.pinInvalid(attemptsLeft: 0)))
    }

    @Test("The phone's PAIRING_CLOSED ends the attempt; silence past the offer timeout is a dropped connection")
    func closedAndSilent() async {
        #expect(await run(qrPhone(.closed)).result == .failure(.pairingClosed))
        #expect(await run(qrPhone(.silent), offerTimeout: .milliseconds(200)).result == .failure(.disconnected))
    }

    @Test("The QR URI: 300 characters at most, d percent-encoded, the name fitted whole characters at a time")
    func invite() throws {
        let key = Data(repeating: 0xAB, count: 32)
        let uri = PairingInvite.uri(clientDHPublicKey: key, pairingSecret: Data((0..<32).map { UInt8($0) }),
                                    name: "MacBook của Lan")
        #expect(uri == "handlive://pair?v=1&pk=q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s"
            + "&ps=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&d=MacBook%20c%E1%BB%A7a%20Lan")
        #expect(PairingInvite.percentEncoded("a+b&c=d~") == "a%2Bb%26c%3Dd~")
        let long = String(repeating: "Điện thoại ", count: 20)
        let fitted = PairingInvite.fittedName(long)
        #expect(fitted.unicodeScalars.count <= 64 && long.hasPrefix(fitted))
        #expect(PairingInvite.uri(clientDHPublicKey: key, pairingSecret: key, name: fitted).count <= 300)
        #expect(PairingInvite.fittedName("  Mac  ") == "Mac")
    }
}
