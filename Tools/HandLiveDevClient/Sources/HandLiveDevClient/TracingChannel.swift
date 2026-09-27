import Foundation
import HLProtocol
import HLTransport

/// A channel that prints what crosses it, for `/v1/pair` whose messages are plaintext: the `op` of each message, the
/// code of a `pair/error`, and how the channel closed. Nonces, keys and MACs are never printed.
final class TracingChannel: MessageChannel, @unchecked Sendable {
    private let base: any MessageChannel
    private let label: String

    init(_ base: any MessageChannel, label: String) {
        self.base = base
        self.label = label
    }

    func receive() async throws -> ChannelMessage {
        do {
            let message = try await base.receive()
            DevConsole.line("\(label) ← \(Self.describe(message))")
            return message
        } catch let closed as ChannelClosed {
            DevConsole.line("\(label) \(closed)")
            throw closed
        }
    }

    func send(_ message: ChannelMessage) async throws {
        DevConsole.line("\(label) → \(Self.describe(message))")
        try await base.send(message)
    }

    func ping(payload: Data, timeout: Duration) async throws {
        try await base.ping(payload: payload, timeout: timeout)
    }

    func close(code: CloseCode) async {
        DevConsole.line("\(label) closing with \(code.rawValue)")
        await base.close(code: code)
    }

    /// `pair/offer`, `pair/error PAIRING_CLOSED`, or the size of anything else.
    static func describe(_ message: ChannelMessage) -> String {
        guard case .text(let text) = message, let envelope = try? Envelope.parse(Data(text.utf8)),
              let plaintext = try? envelope.payloadBytes, let payload = try? Payload.parse(plaintext) else {
            switch message {
            case .text(let text): return "text, \(text.utf8.count) bytes"
            case .binary(let data): return "binary, \(data.count) bytes"
            }
        }
        var line = "\(envelope.type.rawValue)/\(payload.op)"
        if payload.op == "error", case .object(let fields) = payload.data, case .string(let code)? = fields["code"] {
            line += " \(code)"
        }
        return line
    }
}
