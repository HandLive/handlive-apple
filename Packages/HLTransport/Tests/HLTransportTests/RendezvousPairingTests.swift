import Foundation
import HLCrypto
import HLProtocol
import Testing
@testable import HLTransport

/// A relay that only runs pairing rendezvous: the phone "scans" by joining, and `rv_msg` carries the pair envelopes.
actor FakeRendezvousRelay: RelaySocketOpening {
    private var client: InMemoryChannel?
    private var rvId: String?
    private var phoneSide: InMemoryChannel?
    private(set) var outcome: FakePairingPhone.Outcome?

    nonisolated func open(token: String, timeout: Duration) async throws -> any MessageChannel {
        await accept()
    }

    private func accept() -> InMemoryChannel {
        let (clientEnd, relayEnd) = InMemoryChannel.pair()
        client = relayEnd
        Task { await self.readClient(relayEnd) }
        return clientEnd
    }

    /// The phone scanned the code and joins the rendezvous.
    func phoneJoins(_ phone: FakePairingPhone) async {
        let (relaySide, phoneEnd) = InMemoryChannel.pair()
        phoneSide = relaySide
        Task { self.finished(await phone.serve(phoneEnd)) }
        Task { await self.readPhone(relaySide) }
        try? await client?.send(.text(#"{"op":"rv_joined","rv_id":"\#(rvId ?? "")","peer_present":true}"#))
    }

    private func finished(_ result: FakePairingPhone.Outcome) {
        outcome = result
    }

    var joinedRendezvous: String? { rvId }

    private func readClient(_ socket: InMemoryChannel) async {
        while case .text(let text)? = try? await socket.receive() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let op = object["op"] as? String else { continue }
            if op == "rv_join", let id = object["rv_id"] as? String {
                rvId = id
                try? await socket.send(.text(#"{"op":"rv_joined","rv_id":"\#(id)","peer_present":false}"#))
            } else if op == "rv_msg", let env = object["env"], let data = try? JSONSerialization.data(withJSONObject: env) {
                try? await phoneSide?.send(.text(String(bytes: data, encoding: .utf8) ?? ""))
            }
        }
        await phoneSide?.close(code: .normal) // the client left the relay: the phone's exchange is over
    }

    private func readPhone(_ link: InMemoryChannel) async {
        while case .text(let envelope)? = try? await link.receive() {
            try? await client?.send(.text(#"{"op":"rv_msg","rv_id":"\#(rvId ?? "")","env":\#(envelope)}"#))
        }
    }
}

@Suite("Pairing through the relay rendezvous (PAIR-01 step 7, API 7)")
struct RendezvousPairingTests {
    let identity: PairingIdentity
    let secret = PairingCodes.newPairingSecret()

    init() throws {
        identity = try PairingFixtures.identity()
    }

    @Test("The code carries rv; with no window on the LAN the exchange runs inside rv_msg and pairs")
    func pairsThroughRelay() async throws {
        let relay = FakeRendezvousRelay()
        let rendezvous = try await PairingRendezvous.join(relay: RelayServices(api: FakeRelayAPI(), sockets: relay))
        #expect(rendezvous.rvId.count == 16)
        let uri = PairingInvite.uri(clientDHPublicKey: identity.dhPublicKey, pairingSecret: secret, name: "Mac",
                                    rendezvous: rendezvous.rvId)
        #expect(uri.hasSuffix("&rv=\(Base64Coding.encodeB64u(rendezvous.rvId))"))
        let phone = FakePairingPhone(window: .qr(secret: secret, clientDHKey: identity.dhPublicKey))
        let log = ProgressLog()
        var search = PairingSearch(discovery: FakeDiscovery(), connector: FakePairingConnector([]))
        search.pinParameters = PairingFixtures.smallPIN
        let task = Task { [identity, secret, search] in
            try await search.run(identity: identity, credential: .qr(secret: secret, rendezvous: rendezvous),
                                 offerTimeout: .seconds(5), progress: log.add)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await relay.joinedRendezvous == Base64Coding.encodeB64u(rendezvous.rvId))
        await relay.phoneJoins(phone)
        let result = try await task.value
        #expect(result.phoneDeviceId == phone.deviceId)
        #expect(log.all.last == .verifying)
        await rendezvous.close()
        guard case .paired(let pairId, let prk)? = await waitForOutcome(relay) else {
            Issue.record("the phone did not finish")
            return
        }
        #expect(pairId == result.pairId && prk == result.prk)
    }

    @Test("A relay that cannot be reached: no rendezvous, the code goes without rv")
    func unreachableRelay() async throws {
        let api = FakeRelayAPI()
        api.fail(with: .unreachable("offline"))
        await #expect(throws: RelayAPIError.unreachable("offline")) {
            _ = try await PairingRendezvous.join(relay: RelayServices(api: api, sockets: FakeRendezvousRelay()))
        }
    }

    private func waitForOutcome(_ relay: FakeRendezvousRelay) async -> FakePairingPhone.Outcome? {
        for _ in 0..<300 {
            if let outcome = await relay.outcome { return outcome }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}
