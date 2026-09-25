import Foundation
import HLProtocol

/// `type = pair` envelopes on `/v1/pair`, with an unencrypted payload (0.5.1 exception 1).
struct PairingLink: Sendable {
    let channel: any MessageChannel
    let now: @Sendable () -> Int64

    func send<Body: Codable & Sendable & Equatable>(_ op: PairOp, _ data: Body) async throws {
        let plaintext = try TypedPayload(op: op.rawValue, data: data).encoded()
        let envelope = Envelope(type: .pair, id: HLUUID.v7(timestampMs: now()), ts: now(), plainPayload: plaintext)
        try await channel.send(.text(envelope.wireString()))
    }

    /// The next `pair/<op>`; the phone's `pair/error` becomes its failure; anything else is refused as
    /// `AUTH_FAILED`; nothing within `timeout` closes the channel (`disconnected`).
    func receive<Body: Decodable>(_ op: PairOp, as type: Body.Type, timeout: Duration) async throws -> Body {
        let timer = Task { [channel] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await channel.close(code: .normal)
        }
        defer { timer.cancel() }
        let payload = try await nextPayload()
        switch PairOp(rawValue: payload.op) {
        case op:
            guard let data = try? payload.decodeData(as: type) else { throw PairingRefusal.authFailed }
            return data
        case .error:
            let error = try? payload.decodeData(as: PairErrorData.self)
            throw Self.failure(for: error?.code ?? .internal)
        default:
            throw PairingRefusal.authFailed
        }
    }

    private func nextPayload() async throws -> Payload {
        let message: ChannelMessage
        do {
            message = try await channel.receive()
        } catch {
            throw PairingFailure.disconnected
        }
        guard case .text(let text) = message, let envelope = try? Envelope.parse(Data(text.utf8)),
              envelope.type == .pair, let payload = try? Payload.parse(envelope.payloadBytes)
        else { throw PairingRefusal.authFailed }
        return payload
    }

    /// `pair/error` then close (API 6: the sender closes right afterwards).
    func refuse(_ refusal: PairingRefusal) async {
        let error = PairErrorData(code: refusal.code, message: refusal.message,
                                  attemptsLeft: refusal.attemptsLeft.map { Int32($0) })
        try? await send(.error, error)
        await channel.close(code: .normal)
    }

    static func failure(for code: ErrorCode) -> PairingFailure {
        switch code {
        case .pairingClosed: .pairingClosed
        case .authFailed: .authFailed
        default: .rejected(code)
        }
    }
}
