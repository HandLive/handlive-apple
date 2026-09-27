import Foundation
import HLProtocol
import Testing
@testable import HLTransport

/// The relay connection (CONN-03 API 4–6, PAIR-01 API 7): routing to virtual channels, presence, errors, rendezvous.
@Suite("Relay link and its channels")
struct RelayLinkTests {
    static let phone = "8c7d6e5f-4a3b-8c2d-9e1f-0a1b2c3d4e5f"
    static let pairId = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    static let envelope = Envelope(type: .sms, id: "0192f4b2-5c6d-7e8f-9a0b-1c2d3e4f5a6b", ts: 1_727_151_200_000,
                                   payload: Base64Coding.encodeB64(Data([1, 2, 3])))

    static func link() async -> (RelayLink, InMemoryChannel) {
        let (client, relay) = InMemoryChannel.pair()
        let link = RelayLink(socket: client, pingInterval: .seconds(60), pongTimeout: .seconds(1))
        await link.start()
        return (link, relay)
    }

    static func text(_ channel: InMemoryChannel) async throws -> String {
        guard case .text(let text) = try await channel.receive() else { throw ChannelClosed(code: nil, detail: "binary") }
        return text
    }

    @Test("Envelopes go out as {to, env} and come back from {from, env}; other senders are dropped")
    func forwarding() async throws {
        let (link, relay) = await Self.link()
        let channel = await link.channel(to: Self.phone)
        try await channel.send(.text(Self.envelope.wireString()))
        #expect(try await Self.text(relay) == #"{"to":"\#(Self.phone)","env":\#(Self.envelope.wireString())}"#)
        try await relay.send(.text(#"{"from":"5b1f8c2e-9a4d-8e6f-a1b2-c3d4e5f60718","env":\#(Self.envelope.wireString())}"#))
        try await relay.send(.text(#"{"from":"\#(Self.phone)","env":\#(Self.envelope.wireString())}"#))
        #expect(try await channel.receive() == .text(Self.envelope.wireString()))
        await link.close()
    }

    @Test("presence is kept per pair; NOT_CONNECTED closes the peer's channel (E8)")
    func presenceAndNotConnected() async throws {
        let (link, relay) = await Self.link()
        let channel = await link.channel(to: Self.phone)
        let presence = #"{"op":"presence","pair_id":"\#(Self.pairId)","peer_device_id":"\#(Self.phone)","online":true}"#
        try await relay.send(.text(presence))
        try await relay.send(.text(#"{"op":"error","code":"NOT_CONNECTED","message":"","to":"\#(Self.phone)"}"#))
        await #expect(throws: ChannelClosed.self) { _ = try await channel.receive() }
        #expect(await link.presence(pairId: Self.pairId) == true)
        var events: [RelayLinkEvent] = []
        for await event in link.events {
            events.append(event)
            if events.count == 2 { break }
        }
        #expect(events == [.presence(pairId: Self.pairId, peerDeviceId: Self.phone, online: true),
                           .error(code: .notConnected, to: Self.phone)])
        await link.close()
    }

    @Test("Rendezvous: rv_join, the peer's arrival, pair envelopes inside rv_msg")
    func rendezvous() async throws {
        let (link, relay) = await Self.link()
        let rvId = "Eh8kKS4zOD1CR0xRVltgZQ"
        let channel = try await link.joinRendezvous(rvId: rvId)
        #expect(try await Self.text(relay) == #"{"op":"rv_join","rv_id":"\#(rvId)"}"#)
        try await relay.send(.text(#"{"op":"rv_joined","rv_id":"\#(rvId)","peer_present":true}"#))
        #expect(await channel.waitForPeer())
        let hello = Envelope(type: .pair, plainPayload: Data(#"{"op":"hello","data":{}}"#.utf8))
        try await channel.send(.text(hello.wireString()))
        #expect(try await Self.text(relay) == #"{"op":"rv_msg","rv_id":"\#(rvId)","env":\#(hello.wireString())}"#)
        try await relay.send(.text(#"{"op":"rv_msg","rv_id":"\#(rvId)","env":\#(hello.wireString())}"#))
        #expect(try await channel.receive() == .text(hello.wireString()))
        await link.close()
    }

    @Test("When the relay goes away every channel closes and the link reports closed")
    func relayLost() async throws {
        let (link, relay) = await Self.link()
        let channel = await link.channel(to: Self.phone)
        let rendezvous = try await link.joinRendezvous(rvId: "Eh8kKS4zOD1CR0xRVltgZQ")
        _ = try await Self.text(relay)
        await relay.close(code: .normal)
        await #expect(throws: ChannelClosed.self) { _ = try await channel.receive() }
        #expect(await rendezvous.waitForPeer() == false)
        var sawClosed = false
        for await event in link.events where event == .closed { sawClosed = true }
        let closed = await link.isClosed
        #expect(sawClosed && closed)
        await #expect(throws: ChannelClosed.self) { try await channel.send(.text(Self.envelope.wireString())) }
    }
}
