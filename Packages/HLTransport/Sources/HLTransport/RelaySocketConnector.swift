import Foundation
import HLProtocol
import Network
import Security

/// Opens `wss://{RELAY_HOST}/v1/relay` with a JWT (CONN-03 API 4); tests open in-memory relays instead.
public protocol RelaySocketOpening: Sendable {
    func open(token: String, timeout: Duration) async throws -> any MessageChannel
}

/// Network.framework WebSocket to the relay: TLS 1.3, the system's chain and host-name validation plus the SPKI pins
/// (0.4.3), the `Authorization: Bearer` header, automatic pong replies.
public struct RelaySocketConnector: RelaySocketOpening {
    public let configuration: RelayConfiguration

    public init(configuration: RelayConfiguration) {
        self.configuration = configuration
    }

    public func open(token: String, timeout: Duration) async throws -> any MessageChannel {
        guard let url = configuration.relaySocketURL else { throw RelayTransportError.unreachable("no relay URL") }
        let queue = DispatchQueue(label: "app.handlive.relay")
        let pinCheck = RelayPinCheck(host: configuration.host, pins: configuration.spkiPins)
        let connection = NWConnection(to: .url(url), using: parameters(token: token, pinCheck: pinCheck, queue: queue))
        let once = ResumeOnce<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                once.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume(returning: ())
                    case .failed(let error), .waiting(let error):
                        once.resume(throwing: pinCheck.rejected ? RelayTransportError.pinMismatch
                                                                : RelayTransportError.unreachable("\(error)"))
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    once.resume(throwing: RelayTransportError.unreachable("timed out"))
                    connection.cancel()
                }
            }
        } onCancel: {
            once.resume(throwing: CancellationError())
            connection.cancel()
        }
        return WebSocketChannel(connection: connection, queue: queue)
    }

    private func parameters(token: String, pinCheck: RelayPinCheck, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            complete(pinCheck.accept(sec_trust_copy_ref(trust).takeRetainedValue()))
        }, queue)
        let parameters = NWParameters(tls: tls)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = RelayFrame.maxFrameBytes * 2
        websocket.setAdditionalHeaders([(name: "Authorization", value: "Bearer \(token)")])
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }
}

/// Runs `RelayTrust` in the TLS verify block and remembers a refusal, so E7 is told apart from network errors.
final class RelayPinCheck: @unchecked Sendable {
    private let host: String
    private let pins: Set<Data>
    private let lock = NSLock()
    private var didReject = false

    init(host: String, pins: Set<Data>) {
        self.host = host
        self.pins = pins
    }

    var rejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didReject
    }

    func accept(_ trust: SecTrust) -> Bool {
        let accepted = RelayTrust.evaluate(trust, host: host, pins: pins)
        if !accepted {
            lock.lock()
            didReject = true
            lock.unlock()
        }
        return accepted
    }
}
