import Foundation
import HLTransport
import Network

/// The real `WebSocketConnector` (TLS 1.3, certificate pinning, WebSocket) aimed at the `adb forward` address: a
/// discovered service is replaced by `host:port`, because the emulator's mDNS advertisement never reaches macOS.
struct ForwardedConnector: ChannelConnecting {
    let host: String
    let port: UInt16
    let base = WebSocketConnector()

    func connect(to target: ConnectTarget, path: String, policy: CertificatePolicy,
                 timeout: Duration) async throws -> ChannelConnection {
        let forwarded: ConnectTarget = switch target {
        case .service: .host(host, port: port)
        case .host: target
        }
        return try await base.connect(to: forwarded, path: path, policy: policy, timeout: timeout)
    }
}

/// Stands in for the Bonjour browser. `announcePinWindow()` reports the phone's PIN pairing window (TXT `pm = 1`,
/// PAIR-01 A4) once the phone opened it; the connection manager gets nothing and uses the `last_host` fast path.
final class ForwardedDiscovery: LANDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: AsyncStream<DiscoveryEvent>.Continuation] = [:]
    private var phones: [DiscoveredPhone] = []
    let host: String
    let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func events() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            let id = UUID()
            let current = lock.withLock {
                listeners[id] = continuation
                return phones
            }
            continuation.yield(.state(.ready))
            continuation.yield(.results(current))
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
            }
        }
    }

    /// The phone's instance with the PIN window open, at the forwarded address.
    func announcePinWindow() {
        let endpoint = ServiceEndpoint(.hostPort(host: NWEndpoint.Host(host),
                                                 port: NWEndpoint.Port(rawValue: port) ?? .any))
        publish([DiscoveredPhone(name: "HandLive emulator", endpoint: endpoint, txt: ["v": "1", "pm": "1"])])
    }

    func withdraw() {
        publish([])
    }

    private func publish(_ list: [DiscoveredPhone]) {
        let targets = lock.withLock {
            phones = list
            return Array(listeners.values)
        }
        targets.forEach { $0.yield(.results(list)) }
    }
}

/// No network changes to report: the forwarded address is on the loopback interface.
struct SteadyNetwork: NetworkMonitoring {
    func updates() -> AsyncStream<NetworkPathStatus> {
        AsyncStream { continuation in
            continuation.yield(NetworkPathStatus(satisfied: true, signature: "loopback"))
        }
    }
}
