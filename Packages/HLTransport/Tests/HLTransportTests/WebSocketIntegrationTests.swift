import Foundation
import HLProtocol
import Testing
@testable import HLTransport

/// The real Network.framework stack on loopback: TLS 1.3, certificate pinning, WebSocket frames, pings, close codes,
/// and a whole control session against the fake phone on the server side.
@Suite("WebSocket over TLS 1.3 on loopback", .serialized)
struct WebSocketIntegrationTests {
    @Test("Pinned certificate: connects, reports the hash; a wrong pin is TLS_PIN_MISMATCH; recordAny records it")
    func pinning() async throws {
        guard let server = try TLSTestServer.start() else { return } // macOS 13–14: no in-memory identity import
        defer { server.stop() }
        let connector = WebSocketConnector()
        let target = ConnectTarget.host("127.0.0.1", port: server.port)
        let pinned = try await connector.connect(to: target, path: "/v1/ctl", policy: .pinned(server.certificateSHA256),
                                                 timeout: .seconds(5))
        #expect(pinned.certificateSHA256 == server.certificateSHA256)
        #expect(pinned.host == "127.0.0.1" && pinned.port == server.port)
        await pinned.channel.close(code: .normal)
        await #expect(throws: ConnectError.pinMismatch) {
            _ = try await connector.connect(to: target, path: "/v1/ctl", policy: .pinned(Data(repeating: 1, count: 32)),
                                            timeout: .seconds(5))
        }
        let recorded = try await connector.connect(to: target, path: "/v1/pair", policy: .recordAny, timeout: .seconds(5))
        #expect(recorded.certificateSHA256 == server.certificateSHA256)
        await recorded.channel.close(code: .normal)
    }

    @Test("Text and binary frames, ping/pong and a private close code cross the real stack")
    func frames() async throws {
        guard let server = try TLSTestServer.start() else { return }
        defer { server.stop() }
        let connection = try await WebSocketConnector().connect(
            to: .host("127.0.0.1", port: server.port), path: "/v1/ctl", policy: .pinned(server.certificateSHA256),
            timeout: .seconds(5))
        let serverChannel = try #require(await server.accept())
        try await connection.channel.send(.text("xin chào"))
        #expect(try await serverChannel.receive() == .text("xin chào"))
        try await serverChannel.send(.binary(Data([0x48, 0x4C, 1])))
        #expect(try await connection.channel.receive() == .binary(Data([0x48, 0x4C, 1])))
        try await connection.channel.ping(payload: Data(count: 8), timeout: .seconds(2))
        await serverChannel.close(code: .replaced)
        do {
            _ = try await connection.channel.receive()
            Issue.record("the channel should be closed")
        } catch let closed as ChannelClosed {
            #expect(closed.code == .replaced)
        }
    }

    @Test("A whole control session over TLS: handshake, request and ack, phone closes 4409")
    func controlSession() async throws {
        guard let server = try TLSTestServer.start() else { return }
        defer { server.stop() }
        let pair = SessionHarness.pair()
        let connection = try await WebSocketConnector().connect(
            to: .host("127.0.0.1", port: server.port), path: "/v1/ctl", policy: .pinned(server.certificateSHA256),
            timeout: .seconds(5))
        let serverChannel = try #require(await server.accept())
        let phone = FakePhone(channel: serverChannel, pair: pair)
        async let accepted = phone.accept()
        let session = try await ControlSession.establish(over: connection.channel, pair: pair,
                                                         localCapability: SessionHarness.macCapability, route: .lan,
                                                         configuration: SessionHarness.quick())
        #expect(try await accepted == SessionHarness.macCapability)
        let events = EventRecorder(session.events)
        async let answered: Void = {
            let (envelope, _) = try await phone.receiveJSON()
            try await phone.ack(envelope.id)
        }()
        let ack = try await session.request(.clipboard, op: "push", data: ClipText(text: "qua TLS"))
        try await answered
        #expect(ack.ok)
        await serverChannel.close(code: .replaced)
        #expect(await events.ended() == .peerClosed(.replaced))
    }
}
