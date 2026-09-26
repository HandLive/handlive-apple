import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

@Suite("Control session: envelopes, acks and endings (0.5.1, CONN-02)")
struct ControlSessionMessagingTests {
    @Test("A request gets its ack; without one it times out (REQUEST_TIMEOUT)")
    func requestAndTimeout() async throws {
        let connected = try await SessionHarness.connect()
        async let reply: Void = {
            let (envelope, payload) = try await connected.phone.receiveJSON()
            #expect(payload.op == "push")
            try await connected.phone.ack(envelope.id, data: .object(["status": .string("applied")]))
        }()
        let ack = try await connected.session.request(.clipboard, op: "push", data: ClipText(text: "a"))
        try await reply
        #expect(ack.ok && ack.data == .object(["status": .string("applied")]))
        await #expect(throws: SessionError.timedOut) {
            _ = try await connected.session.request(.clipboard, op: "push", data: ClipText(text: "b"))
        }
    }

    @Test("A feature message reaches the app; a repeated id is not handled twice and gets the same ack")
    func incomingAndDuplicates() async throws {
        let connected = try await SessionHarness.connect()
        let push = try await connected.phone.send(.clipboard, op: "push", data: ClipText(text: "xin chào"))
        let event = await connected.events.first { if case .message = $0 { return true } else { return false } }
        guard case .message(let incoming)? = event else { Issue.record("no message"); return }
        #expect(incoming.op == "push" && incoming.id == push.id)
        try await connected.session.reply(to: push.id, with: .success(re: push.id))
        let firstAck = try await connected.phone.receiveEnvelope()
        try await connected.phone.sendRaw(push.wireString())
        let repeatedAck = try await connected.phone.receiveEnvelope()
        #expect(repeatedAck == firstAck)
        try await Task.sleep(for: .milliseconds(50))
        let messages = await connected.events.events.filter { if case .message = $0 { return true } else { return false } }
        #expect(messages.count == 1)
    }

    @Test("Binary clipboard/chunk plaintext arrives as a binary body")
    func binaryChunk() async throws {
        let connected = try await SessionHarness.connect()
        let chunk = try ClipboardChunkPlaintext(transferId: HLUUID.v7(), index: 0, chunk: Data([1, 2, 3])).encoded()
        try await connected.phone.sendPlaintext(.clipboard, chunk)
        let event = await connected.events.first { if case .message = $0 { return true } else { return false } }
        #expect(event == .message(IncomingEnvelope(id: (try? Self.lastID(event)) ?? "", type: .clipboard,
                                                   ts: (try? Self.lastTS(event)) ?? 0, body: .binary(chunk))))
    }

    private static func lastID(_ event: SessionEvent?) throws -> String {
        guard case .message(let incoming)? = event else { throw FakePhoneError.noSession }
        return incoming.id
    }

    private static func lastTS(_ event: SessionEvent?) throws -> Int64 {
        guard case .message(let incoming)? = event else { throw FakePhoneError.noSession }
        return incoming.ts
    }

    @Test("Unhandled request → UNSUPPORTED_TYPE; unhandled event → ignored (0.5.1 rule 3)")
    func unsupported() async throws {
        let connected = try await SessionHarness.connect()
        let request = try await connected.phone.send(.callEvent, op: "action", data: ClipText(text: "x"))
        let ack = try await connected.phone.receiveAck()
        #expect(ack.re == request.id && ack.error?.code == .unsupportedType)
        try await connected.phone.send(.callEvent, op: "state", data: ClipText(text: "x"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await connected.events.events.isEmpty)
    }

    @Test("pair/revoke: ack first, then the app cleans up; a foreign pair_id is BAD_REQUEST")
    func revoke() async throws {
        let connected = try await SessionHarness.connect()
        struct Revoke: Codable, Sendable { let pair_id: String; let reason: String } // swiftlint:disable:this identifier_name
        _ = try await connected.phone.send(.pair, op: "revoke", data: Revoke(pair_id: HLUUID.v7(), reason: "user"))
        #expect(try await connected.phone.receiveAck().error?.code == .badRequest)
        let pairId = SessionHarness.pair().pairId
        _ = try await connected.phone.send(.pair, op: "revoke", data: Revoke(pair_id: pairId, reason: "user"))
        #expect(try await connected.phone.receiveAck().ok)
        #expect(await connected.events.first { $0 == .pairRevoked } != nil)
    }

    @Test("capability/update replaces the stored capability")
    func capabilityUpdate() async throws {
        let connected = try await SessionHarness.connect()
        let original = FakePhone.androidCapability
        let capability = CapabilityData(appVersion: original.appVersion, platform: .android, osVersion: "16",
                                        model: original.model, features: Features(), permissionsMissing: ["READ_SMS"])
        try await connected.phone.send(.capability, op: "update", data: capability)
        #expect(await connected.events.first { $0 == .capabilityUpdated(capability) } != nil)
        #expect(await connected.session.peerCapability == capability)
    }

    @Test("session/bye revoked → remove the pair; 4409 → no reconnect; garbage payload → 4400")
    func endings() async throws {
        let bye = try await SessionHarness.connect()
        try await bye.phone.send(.session, op: "bye", data: SessionByeData(reason: .revoked))
        #expect(await bye.events.ended() == .peerBye(.revoked))
        #expect(SessionEnd.peerBye(.revoked).reaction == .removePair)

        let replaced = try await SessionHarness.connect()
        await replaced.phoneChannel.close(code: .replaced)
        #expect(await replaced.events.ended() == .peerClosed(.replaced))
        #expect(SessionEnd.peerClosed(.replaced).reaction == CloseReaction.none)

        let garbled = try await SessionHarness.connect()
        try await garbled.phone.sendPlaintext(.clipboard, Data("{}".utf8), key: Data(repeating: 7, count: 32))
        #expect(await garbled.events.ended() == .decryptFailed)
        #expect(garbled.phoneChannel.receivedCloseCode == .badRequest)
    }

    @Test("No pong within PONG_TIMEOUT → connection lost (CONN-02 step 3)")
    func pongTimeout() async throws {
        var configuration = SessionHarness.quick()
        configuration.pingInterval = .milliseconds(50)
        let connected = try await SessionHarness.connect(configuration)
        connected.client.stopAnsweringPings()
        #expect(await connected.events.ended() == .pongTimeout)
        await #expect(throws: SessionError.ended) {
            try await connected.session.send(.clipboard, op: "conflict", data: ClipText(text: "late"))
        }
    }

    @Test("close(bye: .shutdown) sends session/bye then closes 1000")
    func shutdown() async throws {
        let connected = try await SessionHarness.connect()
        await connected.session.close(bye: .shutdown)
        let (_, payload) = try await connected.phone.receiveJSON()
        #expect(payload.op == "bye")
        #expect(try payload.decodeData(as: SessionByeData.self).reason == .shutdown)
        #expect(connected.phoneChannel.receivedCloseCode == .normal)
        #expect(await connected.events.ended() == .local(.normal))
    }
}
