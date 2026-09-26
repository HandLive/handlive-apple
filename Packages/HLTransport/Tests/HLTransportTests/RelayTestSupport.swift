import Foundation
import HLCrypto
import HLProtocol
@testable import HLTransport

/// REST side of a fake relay: records what the client asked for and fails on request.
final class FakeRelayAPI: RelayAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: RelayAPIError?
    private(set) var pushes: [RelayPushRequest] = []
    private(set) var registeredPairs: [RelayPairRegistration] = []
    private(set) var tokens = 0
    var pairList = RelayPairList(pairs: [])

    func fail(with error: RelayAPIError?) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    private func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
    }

    var pushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pushes.count
    }

    func registerDevice() async throws { try check() }

    private func locked(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    func accessToken() async throws -> String {
        try check()
        locked { tokens += 1 }
        return "jwt"
    }

    func registerPair(_ registration: RelayPairRegistration) async throws {
        try check()
        locked { registeredPairs.append(registration) }
    }

    func pairs() async throws -> RelayPairList {
        try check()
        return pairList
    }

    func revokePair(pairId: String, reason: RelayPairRevokeRequest.Reason) async throws { try check() }
    func updatePushToken(_ request: RelayPushTokenRequest) async throws { try check() }

    func push(_ request: RelayPushRequest) async throws {
        locked { pushes.append(request) }
        try check()
    }

    func deleteDevice(revokePairs: Bool) async throws { try check() }
}

/// The WebSocket side of a fake relay with one phone behind it: forwards `{"to","env"}` from the client to the phone's
/// channel and wraps what the phone sends as `{"from","env"}`; answers `NOT_CONNECTED` while the phone is offline.
actor FakeRelay: RelaySocketOpening {
    let pair: PairContext
    private var clientSocket: InMemoryChannel?
    private var phoneOnline = false
    private var phoneLink: InMemoryChannel?
    private(set) var phone: FakePhone?
    private(set) var opens = 0
    private(set) var forwarded: [String] = []
    private var loops: [Task<Void, Never>] = []

    init(pair: PairContext) {
        self.pair = pair
    }

    nonisolated func open(token: String, timeout: Duration) async throws -> any MessageChannel {
        await accept()
    }

    private func accept() async -> InMemoryChannel {
        opens += 1
        let (client, server) = InMemoryChannel.pair()
        clientSocket = server
        loops.append(Task { await self.readClient(server) })
        await sendPresence()
        return client
    }

    /// The phone connects to (or leaves) the relay; online answers the handshake like a real phone.
    func setPhoneOnline(_ online: Bool) async {
        phoneOnline = online
        if online {
            let (relaySide, phoneSide) = InMemoryChannel.pair()
            phoneLink = relaySide
            let fake = FakePhone(channel: phoneSide, pair: pair)
            phone = fake
            loops.append(Task { await self.readPhone(relaySide) })
            Task { try? await fake.accept() }
        } else {
            await phoneLink?.close(code: .normal)
            phoneLink = nil
        }
        await sendPresence()
    }

    /// Drops the client's WebSocket as a failing relay would.
    func dropClient() async {
        await clientSocket?.close(code: .normal)
    }

    func sendControl(_ text: String) async {
        try? await clientSocket?.send(.text(text))
    }

    private func sendPresence() async {
        let frame = #"{"op":"presence","pair_id":"\#(pair.pairId)","peer_device_id":"\#(pair.serverDeviceId)","#
            + #""online":\#(phoneOnline)}"#
        try? await clientSocket?.send(.text(frame))
    }

    private func readClient(_ socket: InMemoryChannel) async {
        while let message = try? await socket.receive() {
            guard case .text(let text) = message, let inbound = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any], let to = inbound["to"] as? String, let env = inbound["env"] else { continue }
            forwarded.append(to)
            guard phoneOnline, let phoneLink, let data = try? JSONSerialization.data(withJSONObject: env) else {
                let error = #"{"op":"error","code":"NOT_CONNECTED","message":"offline","to":"\#(to)"}"#
                try? await socket.send(.text(error))
                continue
            }
            try? await phoneLink.send(.text(String(bytes: data, encoding: .utf8) ?? ""))
        }
    }

    private func readPhone(_ link: InMemoryChannel) async {
        while let message = try? await link.receive() {
            guard case .text(let envelope) = message else { continue }
            try? await clientSocket?.send(.text(#"{"from":"\#(pair.serverDeviceId)","env":\#(envelope)}"#))
        }
    }
}
