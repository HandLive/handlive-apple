import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

@Suite("Control session: rekey (0.6.3 step 6, CONN-02 API 3)")
struct ControlSessionRekeyTests {
    private static func rekeyAfter(_ envelopes: Int) -> SessionConfiguration {
        var configuration = SessionHarness.quick()
        configuration.rekeyAfterEnvelopes = envelopes
        return configuration
    }

    @Test("The client starts a rekey after REKEY_AFTER envelopes; both sides switch keys")
    func clientInitiated() async throws {
        let connected = try await SessionHarness.connect(Self.rekeyAfter(3))
        try await connected.session.send(.clipboard, op: "conflict", data: ClipText(text: "1"))
        try await connected.session.send(.clipboard, op: "conflict", data: ClipText(text: "2")) // 3rd envelope
        var request: (Envelope, Payload)?
        for _ in 0..<3 {
            let (envelope, payload) = try await connected.phone.receiveJSON()
            if envelope.type == .session && payload.op == "rekey" { request = (envelope, payload); break }
        }
        let (envelope, payload) = try #require(request)
        #expect(try payload.decodeData(as: SessionRekeyData.self).epoch == 1)
        try await connected.phone.answerRekey(envelope, payload)
        // New keys both ways: the phone reads the next client envelope with the new k_c2s and vice versa.
        try await Task.sleep(for: .milliseconds(50))
        try await connected.session.send(.clipboard, op: "conflict", data: ClipText(text: "after"))
        let (after, afterPayload) = try await connected.phone.receiveJSON()
        #expect(after.type == .clipboard && afterPayload.op == "conflict")
        try await connected.phone.send(.clipboard, op: "push", data: ClipText(text: "new key"))
        #expect(await connected.events.first { if case .message = $0 { return true } else { return false } } != nil)
    }

    @Test("The phone starts a rekey; the client acks under the old key and switches")
    func phoneInitiated() async throws {
        let connected = try await SessionHarness.connect()
        let offer = try await connected.phone.startRekey()
        let ack = try await connected.phone.receiveAck() // sealed with the old k_c2s
        #expect(ack.re == offer.id && ack.ok)
        try await connected.phone.finishRekey(offer, ack: ack)
        try await connected.session.send(.clipboard, op: "conflict", data: ClipText(text: "new"))
        let (envelope, _) = try await connected.phone.receive()
        #expect(envelope.type == .clipboard)
        try await connected.phone.send(.clipboard, op: "push", data: ClipText(text: "x"))
        #expect(await connected.events.first { if case .message = $0 { return true } else { return false } } != nil)
    }

    @Test("A rekey request with the wrong epoch is refused with BAD_REQUEST")
    func wrongEpoch() async throws {
        let connected = try await SessionHarness.connect()
        let data = SessionRekeyData(epoch: 5, eph: Base64Coding.encodeB64u(Data(repeating: 9, count: 32)),
                                    nonce: Base64Coding.encodeB64u(Data(repeating: 1, count: 32)))
        _ = try await connected.phone.send(.session, op: "rekey", data: data)
        #expect(try await connected.phone.receiveAck().error?.code == .badRequest)
    }

    @Test("No ack to the client's rekey → close 4410 REKEY_FAILED (E4)")
    func rekeyWithoutAck() async throws {
        let connected = try await SessionHarness.connect(Self.rekeyAfter(2))
        try await connected.session.send(.clipboard, op: "conflict", data: ClipText(text: "1"))
        #expect(await connected.events.ended() == .rekeyFailed)
        #expect(connected.phoneChannel.receivedCloseCode == .rekeyFailed)
    }

    @Test("Simultaneous rekeys: the smaller device_id wins", arguments: [true, false])
    func collision(clientHasSmallerId: Bool) async throws {
        let connected = try await SessionHarness.connect(Self.rekeyAfter(2), clientFirst: clientHasSmallerId)
        try await connected.session.send(.clipboard, op: "conflict", data: ClipText(text: "trigger"))
        var clientRequest: (Envelope, Payload)?
        for _ in 0..<3 {
            let (envelope, payload) = try await connected.phone.receiveJSON()
            if payload.op == "rekey" { clientRequest = (envelope, payload); break }
        }
        let (requestEnvelope, requestPayload) = try #require(clientRequest)
        let offer = try await connected.phone.startRekey() // both requests are now in flight
        if clientHasSmallerId {
            // The client wins: it ignores the phone's request; the phone answers the client's.
            try await connected.phone.answerRekey(requestEnvelope, requestPayload)
        } else {
            // The phone wins: the client drops its own request and answers the phone's.
            let ack = try await connected.phone.receiveAck()
            #expect(ack.re == offer.id && ack.ok)
            try await connected.phone.finishRekey(offer, ack: ack)
        }
        try await connected.phone.send(.clipboard, op: "push", data: ClipText(text: "new keys"))
        #expect(await connected.events.first { if case .message = $0 { return true } else { return false } } != nil)
        try await Task.sleep(for: .milliseconds(400)) // longer than REQUEST_TIMEOUT: the dropped request ends nothing
        #expect(await connected.events.events.allSatisfy { if case .ended = $0 { return false } else { return true } })
        try await connected.session.send(.clipboard, op: "conflict", data: ClipText(text: "still here"))
        let (after, _) = try await connected.phone.receive()
        #expect(after.type == .clipboard)
    }
}
