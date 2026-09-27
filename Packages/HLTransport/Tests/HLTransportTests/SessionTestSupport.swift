import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

enum SessionHarness {
    static let smallerDeviceId = "11111111-1111-8111-8111-111111111111"
    static let largerDeviceId = "22222222-2222-8222-8222-222222222222"

    /// A pair with a random `PRK`; by default the client has the smaller `device_id`.
    static func pair(clientFirst: Bool = true) -> PairContext {
        PairContext(pairId: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                    clientDeviceId: clientFirst ? smallerDeviceId : largerDeviceId,
                    serverDeviceId: clientFirst ? largerDeviceId : smallerDeviceId,
                    prk: SessionHandshakeCrypto.randomNonce())
    }

    static let macCapability = CapabilityData(
        appVersion: "0.0.1 (1)", platform: .macos, osVersion: "15.6", model: "Mac15,3",
        features: Features(clipboard: ClipboardFeature(enabled: true, autoSend: true, maxTextBytes: 1_048_576,
                                                       maxImageBytes: 10_485_760,
                                                       mimes: ["text/plain", "image/png", "image/jpeg"]),
                           relay: RelayFeature(enabled: true)))

    static func quick() -> SessionConfiguration {
        var configuration = SessionConfiguration()
        configuration.handshakeTimeout = .milliseconds(500)
        configuration.requestTimeout = .milliseconds(300)
        configuration.pingInterval = .seconds(60)
        configuration.pongTimeout = .milliseconds(100)
        return configuration
    }

    struct Connected {
        let session: ControlSession
        let phone: FakePhone
        let client: InMemoryChannel
        let phoneChannel: InMemoryChannel
        let events: EventRecorder
        let clientCapabilitySeenByPhone: CapabilityData
    }

    static func connect(_ configuration: SessionConfiguration = quick(), clientFirst: Bool = true,
                        route: ConnectionRoute = .lan) async throws -> Connected {
        let pair = pair(clientFirst: clientFirst)
        let (client, phoneChannel) = InMemoryChannel.pair()
        let phone = FakePhone(channel: phoneChannel, pair: pair)
        async let accepted = phone.accept()
        let session = try await ControlSession.establish(over: client, pair: pair, localCapability: macCapability,
                                                         route: route, configuration: configuration)
        let seen = try await accepted
        return Connected(session: session, phone: phone, client: client, phoneChannel: phoneChannel,
                         events: EventRecorder(session.events), clientCapabilitySeenByPhone: seen)
    }
}

/// Collects session events and waits for one that matches.
actor EventRecorder {
    private(set) var events: [SessionEvent] = []

    init(_ stream: AsyncStream<SessionEvent>) {
        Task { await self.consume(stream) }
    }

    private func consume(_ stream: AsyncStream<SessionEvent>) async {
        for await event in stream { events.append(event) }
    }

    func first(timeout: Duration = .seconds(2), where match: @Sendable (SessionEvent) -> Bool) async -> SessionEvent? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let event = events.first(where: match) { return event }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func ended(timeout: Duration = .seconds(2)) async -> SessionEnd? {
        guard case .ended(let reason)? = await first(timeout: timeout, where: {
            if case .ended = $0 { return true }
            return false
        }) else { return nil }
        return reason
    }
}

struct ClipText: Codable, Sendable, Equatable {
    let text: String
}
