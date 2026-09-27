import Foundation
import HLCrypto
import HLProtocol
@testable import HLTransport

/// Android's side of `/v1/pair` (PAIR-01 API 2–6), written from the spec with HLCrypto, with switches to misbehave.
final class FakePairingPhone: @unchecked Sendable {
    enum Window {
        case qr(secret: Data, clientDHKey: Data)
        /// The PIN the user typed on the phone.
        case pin(String)
    }

    enum Fault {
        case none, wrongOfferMac, wrongDeviceId, wrongDoneSignature, wrongDonePrkCheck, wrongDoneMac
        /// Answers `pair/hello` with `pair/error PAIRING_CLOSED`.
        case closed
        /// Never answers.
        case silent
    }

    enum Outcome: Equatable {
        case paired(pairId: String, prk: Data)
        case clientRefused(PairErrorData)
        case failed(String)
    }

    let signingSeed = Ed25519.generateSeed()
    let dhPrivateKey = X25519.generatePrivateKey()
    let tlsSHA256 = Data(repeating: 0xAB, count: 32)
    let name = "Pixel của Lan"
    let window: Window
    let fault: Fault
    let pinParameters: Argon2id.Parameters
    var signingPublicKey: Data { (try? Ed25519.publicKey(seed: signingSeed)) ?? Data() }
    var dhPublicKey: Data { (try? X25519.publicKey(privateKey: dhPrivateKey)) ?? Data() }
    var deviceId: String { (try? DeviceIdentity.deviceId(signingPublicKey: signingPublicKey)) ?? "" }

    init(window: Window, fault: Fault = .none, pinParameters: Argon2id.Parameters = PairingFixtures.smallPIN) {
        self.window = window
        self.fault = fault
        self.pinParameters = pinParameters
    }

    /// Serves one connection until the exchange ends.
    func serve(_ channel: any MessageChannel) async -> Outcome {
        do {
            guard case .data(let hello) = try await receive(channel, .hello, as: PairHelloData.self) else {
                return .failed("no hello")
            }
            switch fault {
            case .closed:
                try await send(channel, .error, PairErrorData(code: .pairingClosed, message: "Pairing window is closed"))
                await channel.close(code: .normal)
                return .failed("closed")
            case .silent:
                _ = try? await channel.receive()
                return .failed("silent")
            default:
                return try await offerAndFinish(channel, hello: hello)
            }
        } catch {
            return .failed("\(error)")
        }
    }

    private func offerAndFinish(_ channel: any MessageChannel, hello: PairHelloData) async throws -> Outcome {
        let clientNonce = try Base64Coding.decodeB64u(hello.nonce)
        let clientSig = try Base64Coding.decodeB64u(hello.ikSigPub)
        let clientDH = try Base64Coding.decodeB64u(hello.ikDhPub)
        let serverNonce = PairingCodes.newNonce()
        let secret: Data = switch window {
        case .qr(let secret, _): secret
        case .pin(let typed): await PairingAuthDerivation.pinKeyOffPool(pin: typed, clientNonce: clientNonce,
                                                                        serverNonce: serverNonce, parameters: pinParameters)
        }
        let transcript = try PairingAuthDerivation.offerTranscript(
            client: PairingParty(deviceId: hello.deviceId, nonce: clientNonce, signingPublicKey: clientSig,
                                 dhPublicKey: clientDH, name: hello.name),
            server: PairingParty(deviceId: deviceId, nonce: serverNonce, signingPublicKey: signingPublicKey,
                                 dhPublicKey: dhPublicKey, name: name),
            tlsSHA256: tlsSHA256)
        let authKey = PairingAuthDerivation.authKey(secret: secret, clientNonce: clientNonce, serverNonce: serverNonce)
        var mac = PairingAuthDerivation.offerMac(authKey: authKey, transcript: transcript)
        if fault == .wrongOfferMac { mac[0] ^= 1 }
        let offeredId = fault == .wrongDeviceId ? "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f" : deviceId
        try await send(channel, .offer, PairOfferData(
            deviceId: offeredId, nonce: Base64Coding.encodeB64u(serverNonce), name: name, model: "Pixel 8",
            osVersion: "15", ikSigPub: Base64Coding.encodeB64u(signingPublicKey),
            ikDhPub: Base64Coding.encodeB64u(dhPublicKey), tlsSha256: Base64Coding.encodeB64u(tlsSHA256),
            mac: Base64Coding.encodeB64u(mac)))
        switch try await receive(channel, .confirm, as: PairConfirmData.self) {
        case .error(let error):
            return .clientRefused(error)
        case .data(let confirm):
            let prk = try PairingKeyDerivation.prk(ownDHPrivateKey: dhPrivateKey, peerDHPublicKey: clientDH,
                                                   pairingSecret: secret, ownDeviceId: deviceId, peerDeviceId: hello.deviceId)
            return try await finish(channel, confirm: confirm, hello: hello,
                                    context: ExchangeKeys(authKey: authKey, transcript: transcript, prk: prk))
        }
    }

    struct ExchangeKeys {
        let authKey: Data
        let transcript: Data
        let prk: Data
    }

    private func finish(_ channel: any MessageChannel, confirm: PairConfirmData, hello: PairHelloData,
                        context: ExchangeKeys) async throws -> Outcome {
        let clientSig = try Base64Coding.decodeB64u(hello.ikSigPub)
        let signatureC = try Base64Coding.decodeB64u(confirm.sig)
        let expectedMac = try PairingAuthDerivation.confirmMac(
            authKey: context.authKey, transcript: context.transcript, pairId: confirm.pairId,
            createdAt: confirm.createdAt, clientSignature: signatureC)
        let expectedCheck = try PairingAuthDerivation.prkCheck(prk: context.prk, pairId: confirm.pairId, role: .client)
        let attestation = try PairingAuthDerivation.attestation(PairingAttestationFields(
            pairId: confirm.pairId, androidDeviceId: deviceId, clientDeviceId: hello.deviceId,
            androidSigningKey: signingPublicKey, clientSigningKey: clientSig, createdAt: confirm.createdAt))
        guard try Base64Coding.decodeB64u(confirm.mac) == expectedMac,
              try Base64Coding.decodeB64u(confirm.prkCheck) == expectedCheck,
              Ed25519.verify(signatureC, message: attestation, publicKey: clientSig)
        else {
            try await send(channel, .error, PairErrorData(code: .authFailed, message: "Pairing authentication failed"))
            return .failed("confirm rejected")
        }
        var signature = try Ed25519.sign(attestation, seed: signingSeed)
        var check = try PairingAuthDerivation.prkCheck(prk: context.prk, pairId: confirm.pairId, role: .server)
        var mac = try PairingAuthDerivation.doneMac(authKey: context.authKey, pairId: confirm.pairId,
                                                    serverSignature: signature)
        switch fault {
        case .wrongDoneSignature:
            signature[5] ^= 1
            mac = try PairingAuthDerivation.doneMac(authKey: context.authKey, pairId: confirm.pairId,
                                                    serverSignature: signature)
        case .wrongDonePrkCheck: check[0] ^= 1
        case .wrongDoneMac: mac[0] ^= 1
        default: break
        }
        try await send(channel, .done, PairDoneData(sig: Base64Coding.encodeB64u(signature),
                                                    prkCheck: Base64Coding.encodeB64u(check),
                                                    mac: Base64Coding.encodeB64u(mac)))
        // The client closes with 1000 or refuses with pair/error.
        if case .text(let text) = try? await channel.receive(), let payload = Self.payload(text),
           let error = try? payload.decodeData(as: PairErrorData.self) {
            return .clientRefused(error)
        }
        return .paired(pairId: confirm.pairId, prk: context.prk)
    }

    enum Received<Body> {
        case data(Body)
        case error(PairErrorData)
    }

    private func receive<Body: Decodable>(_ channel: any MessageChannel, _ op: PairOp,
                                          as type: Body.Type) async throws -> Received<Body> {
        guard case .text(let text) = try await channel.receive(), let payload = Self.payload(text) else {
            throw PairingFailure.disconnected
        }
        if payload.op == PairOp.error.rawValue { return .error(try payload.decodeData(as: PairErrorData.self)) }
        guard payload.op == op.rawValue else { throw PairingFailure.authFailed }
        return .data(try payload.decodeData(as: type))
    }

    static func payload(_ text: String) -> Payload? {
        guard let envelope = try? Envelope.parse(Data(text.utf8)), envelope.type == .pair,
              let bytes = try? envelope.payloadBytes else { return nil }
        return try? Payload.parse(bytes)
    }

    private func send<Body: Codable & Sendable & Equatable>(_ channel: any MessageChannel, _ op: PairOp,
                                                            _ data: Body) async throws {
        let envelope = Envelope(type: .pair, plainPayload: try TypedPayload(op: op.rawValue, data: data).encoded())
        try await channel.send(.text(envelope.wireString()))
    }
}

/// Keys and names of the Mac side in pairing tests.
enum PairingFixtures {
    /// Argon2id small enough for debug test builds; the exchange must use the same.
    static let smallPIN = Argon2id.Parameters(passes: 1, memoryKiB: 64, lanes: 4, tagLength: 32)

    static func identity() throws -> PairingIdentity {
        let seed = Ed25519.generateSeed()
        let dh = X25519.generatePrivateKey()
        let signing = try Ed25519.publicKey(seed: seed)
        return PairingIdentity(deviceId: try DeviceIdentity.deviceId(signingPublicKey: signing), name: "MacBook của Lan",
                               platform: .macos, model: "Mac15,3", signingSeed: seed, signingPublicKey: signing,
                               dhPrivateKey: dh, dhPublicKey: try X25519.publicKey(privateKey: dh))
    }
}
