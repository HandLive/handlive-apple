import Foundation
import HLCrypto
import HLProtocol
@testable import HLTransport

/// The Android side of `/v1/ctl` for tests: the server role of 0.6.3 written with HLCrypto primitives only, so the
/// client session is checked against an independent implementation of the handshake and the rekey.
actor FakePhone {
    enum HelloAnswer {
        case welcome
        case error(ErrorCode)
        case welcomeWithBadMac
        case silence
    }

    let channel: any MessageChannel
    let pair: PairContext
    let capability: CapabilityData
    private(set) var keys: SessionKeys?
    private var previousClientKey: Data?
    private(set) var epoch: Int32 = 0

    init(channel: any MessageChannel, pair: PairContext, capability: CapabilityData = FakePhone.androidCapability) {
        self.channel = channel
        self.pair = pair
        self.capability = capability
    }

    static let androidCapability = CapabilityData(
        appVersion: "1.0.0 (100)", platform: .android, osVersion: "15", model: "Pixel 8",
        features: Features(clipboard: ClipboardFeature(enabled: true, autoSend: true, maxTextBytes: 1_048_576,
                                                       maxImageBytes: 10_485_760,
                                                       mimes: ["text/plain", "image/png", "image/jpeg"]),
                           relay: RelayFeature(enabled: true)),
        permissionsMissing: [])

    /// Full handshake: welcome, then `capability/hello` both ways. Returns the client's capability.
    @discardableResult
    func accept() async throws -> CapabilityData {
        try await answerHello(.welcome)
        _ = try await send(.capability, op: "hello", data: capability)
        let (_, payload) = try await receiveJSON()
        return try payload.decodeData(as: CapabilityData.self)
    }

    func answerHello(_ answer: HelloAnswer) async throws {
        let hello = try await receiveEnvelope()
        let data = try Payload.parse(hello.payloadBytes).decodeData(as: SessionHelloData.self)
        let authKey = try SessionHandshakeCrypto.authKey(prk: pair.prk)
        let clientEph = try Base64Coding.decodeB64u(data.eph)
        let t1 = try SessionHandshakeCrypto.helloTranscript(
            pairId: data.pairId, clientDeviceId: data.deviceId, clientEph: clientEph,
            clientNonce: try Base64Coding.decodeB64u(data.nonce))
        guard HMACSHA256.verify(try Base64Coding.decodeB64u(data.mac), key: authKey, message: t1) else {
            throw FakePhoneError.badClientMac
        }
        switch answer {
        case .silence:
            return
        case .error(let code):
            let error = SessionErrorData(code: code, message: "rejected by the test phone",
                                         minProtocol: code == .unsupportedVersion ? 2 : nil)
            let plaintext = try TypedPayload(op: "error", data: error).encoded()
            try await channel.send(.text(Envelope(type: .session, plainPayload: plaintext).wireString()))
            await channel.close(code: code == .pairRevoked ? .pairRevoked : .authFailed)
        case .welcome, .welcomeWithBadMac:
            let ephPrivate = X25519.generatePrivateKey()
            let ephPublic = try X25519.publicKey(privateKey: ephPrivate)
            let nonce = SessionHandshakeCrypto.randomNonce()
            let t2 = try SessionHandshakeCrypto.welcomeTranscript(
                helloTranscript: t1, serverDeviceId: pair.serverDeviceId, serverEph: ephPublic, serverNonce: nonce)
            var mac = HMACSHA256.mac(key: authKey, message: t2)
            if case .welcomeWithBadMac = answer { mac[0] ^= 0xFF }
            let welcome = SessionWelcomeData(deviceId: pair.serverDeviceId, eph: Base64Coding.encodeB64u(ephPublic),
                                             nonce: Base64Coding.encodeB64u(nonce), mac: Base64Coding.encodeB64u(mac))
            let plaintext = try TypedPayload(op: "welcome", data: welcome).encoded()
            try await channel.send(.text(Envelope(type: .session, plainPayload: plaintext).wireString()))
            let shared = try X25519.sharedSecret(privateKey: ephPrivate, peerPublicKey: clientEph)
            keys = try SessionHandshakeCrypto.sessionKeys(ephemeralShared: shared, prk: pair.prk, welcomeTranscript: t2)
        }
    }

    // MARK: - Messages

    @discardableResult
    func send<Body: Encodable & Sendable>(_ type: MessageType, op: String, data: Body,
                                          id: String = HLUUID.v7()) async throws -> Envelope {
        let plaintext = try TypedPayloadEncoder.encode(op: op, data: data)
        return try await sendPlaintext(type, plaintext, id: id)
    }

    @discardableResult
    func sendPlaintext(_ type: MessageType, _ plaintext: Data, id: String = HLUUID.v7(),
                       key: Data? = nil) async throws -> Envelope {
        guard let sendKey = key ?? keys?.serverToClient else { throw FakePhoneError.noSession }
        let envelope = try EnvelopeCipher.seal(type: type, plaintext: plaintext, key: sendKey, id: id)
        try await channel.send(.text(envelope.wireString()))
        return envelope
    }

    func sendRaw(_ text: String) async throws {
        try await channel.send(.text(text))
    }

    func ack(_ requestId: String, data: JSONValue = .emptyObject) async throws {
        _ = try await sendPlaintext(.ack, try Ack.success(re: requestId, data: data).encoded())
    }

    func receiveEnvelope() async throws -> Envelope {
        while true {
            if case .text(let text) = try await channel.receive() { return try Envelope.parse(Data(text.utf8)) }
        }
    }

    /// Next envelope from the client, decrypted with `k_c2s` (or the key before the last rekey).
    func receive() async throws -> (Envelope, Data) {
        let envelope = try await receiveEnvelope()
        guard let keys else { throw FakePhoneError.noSession }
        if let plaintext = try? EnvelopeCipher.open(envelope, key: keys.clientToServer) { return (envelope, plaintext) }
        guard let previousClientKey else { throw FakePhoneError.cannotDecrypt }
        return (envelope, try EnvelopeCipher.open(envelope, key: previousClientKey))
    }

    func receiveJSON() async throws -> (Envelope, Payload) {
        let (envelope, plaintext) = try await receive()
        return (envelope, try Payload.parse(plaintext))
    }

    func receiveAck() async throws -> Ack {
        let (envelope, plaintext) = try await receive()
        guard envelope.type == .ack else { throw FakePhoneError.unexpected(envelope.type.rawValue) }
        return try Ack.parse(plaintext)
    }

    // MARK: - Rekey (0.6.3 step 6)

    struct RekeyOffer {
        let id: String
        let privateKey: Data
        let nonce: Data
        let epoch: Int32
    }

    func startRekey() async throws -> RekeyOffer {
        let privateKey = X25519.generatePrivateKey()
        let nonce = SessionHandshakeCrypto.randomNonce()
        let data = SessionRekeyData(epoch: epoch + 1, eph: Base64Coding.encodeB64u(try X25519.publicKey(privateKey: privateKey)),
                                    nonce: Base64Coding.encodeB64u(nonce))
        let envelope = try await send(.session, op: "rekey", data: data)
        return RekeyOffer(id: envelope.id, privateKey: privateKey, nonce: nonce, epoch: epoch + 1)
    }

    /// Phone as initiator: switch when the client's `ack` arrives.
    func finishRekey(_ offer: RekeyOffer, ack: Ack) throws {
        guard let keys, let data = ack.data else { throw FakePhoneError.noSession }
        let answer = try HLJSON.convert(data, to: SessionRekeyData.self)
        let shared = try X25519.sharedSecret(privateKey: offer.privateKey, peerPublicKey: try Base64Coding.decodeB64u(answer.eph))
        install(try keys.rekeyed(ephemeralShared: shared, initiatorNonce: offer.nonce,
                                 responderNonce: try Base64Coding.decodeB64u(answer.nonce)), epoch: answer.epoch)
    }

    /// Phone as responder: `ack` under the old key, then switch.
    func answerRekey(_ envelope: Envelope, _ payload: Payload) async throws {
        guard let keys else { throw FakePhoneError.noSession }
        let request = try payload.decodeData(as: SessionRekeyData.self)
        let privateKey = X25519.generatePrivateKey()
        let nonce = SessionHandshakeCrypto.randomNonce()
        let shared = try X25519.sharedSecret(privateKey: privateKey, peerPublicKey: try Base64Coding.decodeB64u(request.eph))
        let newKeys = try keys.rekeyed(ephemeralShared: shared, initiatorNonce: try Base64Coding.decodeB64u(request.nonce),
                                       responderNonce: nonce)
        let publicKey = try X25519.publicKey(privateKey: privateKey)
        let answer = SessionRekeyData(epoch: request.epoch, eph: Base64Coding.encodeB64u(publicKey),
                                      nonce: Base64Coding.encodeB64u(nonce))
        try await ack(envelope.id, data: try HLJSON.convert(from: answer))
        install(newKeys, epoch: request.epoch)
    }

    private func install(_ newKeys: SessionKeys, epoch newEpoch: Int32) {
        previousClientKey = keys?.clientToServer
        keys = newKeys
        epoch = newEpoch
    }
}

enum FakePhoneError: Error {
    case badClientMac
    case noSession
    case cannotDecrypt
    case unexpected(String)
}
