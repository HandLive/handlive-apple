import CryptoKit
import Foundation
import HLProtocol
import Network
import Security

/// A Bonjour service found by the browser, to be resolved to an address before connecting.
public struct ServiceEndpoint: @unchecked Sendable, Hashable {
    public let endpoint: NWEndpoint

    public init(_ endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }
}

/// Where to connect: a discovered service or a known `last_host:last_port` (CONN-01 step 2).
public enum ConnectTarget: Sendable, Hashable {
    case service(ServiceEndpoint)
    case host(String, port: UInt16)
}

/// How the server certificate is checked. There is no hostname check; the certificate is self-signed (0.4.1).
public enum CertificatePolicy: Sendable, Equatable {
    /// `/v1/ctl`: the SHA-256 of the DER certificate must equal the pin taken at pairing.
    case pinned(Data)
    /// `/v1/pair`: any certificate, its SHA-256 is recorded and later checked against `tls_sha256` (PAIR-01 step 8).
    case recordAny
}

public enum ConnectError: Error, Sendable, Equatable {
    /// `TLS_PIN_MISMATCH`: drop this instance, try the next one (CONN-01 E2).
    case pinMismatch
    /// The service could not be resolved to an IPv4 address.
    case unresolved
    /// Network or TLS error other than a pin mismatch.
    case failed(String)
    case timedOut
}

/// An open channel and what the TLS handshake revealed.
public struct ChannelConnection: Sendable {
    public let channel: any MessageChannel
    /// SHA-256 of the server's leaf certificate (DER).
    public let certificateSHA256: Data
    /// Address actually used, to store as `last_host` / `last_port` (CONN-01 API 2 logic 2).
    public let host: String
    public let port: UInt16
}

/// Opens WebSocket channels; the connection manager and pairing depend on this protocol so tests can connect
/// to in-memory peers.
public protocol ChannelConnecting: Sendable {
    func connect(to target: ConnectTarget, path: String, policy: CertificatePolicy,
                 timeout: Duration) async throws -> ChannelConnection
}

/// Network.framework implementation: TLS 1.3 minimum, certificate pinning in the verify block, WebSocket
/// with automatic pong replies. A Bonjour service is first resolved to its IPv4 address with a short TCP
/// connection, because a WebSocket request path (`/v1/ctl`) can only be given through a URL endpoint.
public struct WebSocketConnector: ChannelConnecting {
    public init() {}

    public func connect(to target: ConnectTarget, path: String, policy: CertificatePolicy,
                        timeout: Duration) async throws -> ChannelConnection {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let (host, port) = switch target {
        case .host(let host, let port): (host, port)
        case .service(let service): try await Self.resolve(service, timeout: timeout)
        }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw ConnectError.timedOut }
        return try await Self.open(host: host, port: port, path: path, policy: policy, timeout: remaining)
    }

    // MARK: - Resolution

    static func resolve(_ service: ServiceEndpoint, timeout: Duration) async throws -> (String, UInt16) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: service.endpoint, using: parameters)
        let queue = DispatchQueue(label: "app.handlive.resolve")
        let once = ResumeOnce<(String, UInt16)>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                           let address = Self.ipv4String(host) {
                            once.resume(returning: (address, port.rawValue))
                        } else {
                            once.resume(throwing: ConnectError.unresolved)
                        }
                        connection.cancel()
                    case .failed(let error), .waiting(let error):
                        once.resume(throwing: ConnectError.failed("resolve: \(error)"))
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    once.resume(throwing: ConnectError.timedOut)
                    connection.cancel()
                }
            }
        } onCancel: {
            once.resume(throwing: CancellationError())
            connection.cancel()
        }
    }

    static func ipv4String(_ host: NWEndpoint.Host) -> String? {
        guard case .ipv4(let address) = host else { return nil }
        return address.rawValue.map(String.init).joined(separator: ".")
    }

    // MARK: - TLS + WebSocket

    static func open(host: String, port: UInt16, path: String, policy: CertificatePolicy,
                     timeout: Duration) async throws -> ChannelConnection {
        guard let url = URL(string: "wss://\(host):\(port)\(path)") else { throw ConnectError.unresolved }
        let queue = DispatchQueue(label: "app.handlive.websocket")
        let verification = CertificateCheck(policy: policy)
        let connection = NWConnection(to: .url(url), using: parameters(verification: verification, queue: queue))
        let once = ResumeOnce<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                once.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume(returning: ())
                    case .failed(let error), .waiting(let error):
                        // A failed verify block leaves the connection `.waiting` with a TLS error.
                        once.resume(throwing: verification.mismatched ? ConnectError.pinMismatch
                                                                      : ConnectError.failed("\(error)"))
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    once.resume(throwing: ConnectError.timedOut)
                    connection.cancel()
                }
            }
        } onCancel: {
            once.resume(throwing: CancellationError())
            connection.cancel()
        }
        guard let certificate = verification.certificateSHA256 else {
            connection.cancel()
            throw ConnectError.failed("no server certificate")
        }
        let channel = WebSocketChannel(connection: connection, queue: queue)
        return ChannelConnection(channel: channel, certificateSHA256: certificate, host: host, port: port)
    }

    static func parameters(verification: CertificateCheck, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            complete(verification.verify(sec_trust_copy_ref(trust).takeRetainedValue()))
        }, queue)
        let parameters = NWParameters(tls: tls)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = Envelope.maxWireBytes * 2
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }
}
