import dnssd
import Foundation
import Network

/// A HandLive phone seen on the LAN: its random instance name and TXT record (0.4.1).
public struct DiscoveredPhone: Sendable, Hashable {
    public let name: String
    public let endpoint: ServiceEndpoint
    public let txt: [String: String]

    public init(name: String, endpoint: ServiceEndpoint, txt: [String: String]) {
        self.name = name
        self.endpoint = endpoint
        self.txt = txt
    }

    /// Protocol version `v`; only `1` is understood (CONN-01 API 2 logic 1).
    public var speaksProtocolV1: Bool { txt["v"] == "1" }
    /// Hint list `h` (one hint per pair of the phone).
    public var hints: String { txt["h"] ?? "" }
    /// `pr`: first 8 hex of SHA-256(`pk` of the QR), only while QR pairing is open (PAIR-01 step 6).
    public var pairingKeyHash: String? { txt["pr"] }
    /// `pm = 1`: PIN pairing is open (PAIR-01 A4).
    public var pinPairingOpen: Bool { txt["pm"] == "1" }
}

public enum DiscoveryState: Sendable, Equatable {
    case starting
    case ready
    /// The user denied local network access (SET-03 E4, CONN-01 E8): `NWBrowser` waits with PolicyDenied.
    case localNetworkDenied
    case failed(String)
}

public enum DiscoveryEvent: Sendable, Equatable {
    /// Every phone currently visible (a full snapshot).
    case results([DiscoveredPhone])
    case state(DiscoveryState)
}

/// Browses for phones; browsing stops when the consumer stops iterating the stream.
public protocol LANDiscovering: Sendable {
    func events() -> AsyncStream<DiscoveryEvent>
}

/// `NWBrowser` for `_handlive._tcp` with TXT records (CONN-01 API 2, SET-03 API 5).
public struct BonjourDiscovery: LANDiscovering {
    public init() {}

    public func events() -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "app.handlive.discovery")
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: TransportConstants.serviceType, domain: nil),
                                    using: .tcp)
            browser.stateUpdateHandler = { state in
                if let mapped = Self.state(state) { continuation.yield(.state(mapped)) }
            }
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(.results(results.compactMap(Self.phone)))
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    static func state(_ state: NWBrowser.State) -> DiscoveryState? {
        switch state {
        case .setup: return .starting
        case .ready: return .ready
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                return .localNetworkDenied
            }
            return .failed("\(error)")
        case .cancelled: return nil
        @unknown default: return nil
        }
    }

    static func phone(_ result: NWBrowser.Result) -> DiscoveredPhone? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata { txt = record.dictionary }
        return DiscoveredPhone(name: name, endpoint: ServiceEndpoint(result.endpoint), txt: txt)
    }
}

/// Whether the Mac has a network path, and a signature that changes when the default network changes.
public struct NetworkPathStatus: Sendable, Equatable {
    public let satisfied: Bool
    public let signature: String

    public init(satisfied: Bool, signature: String) {
        self.satisfied = satisfied
        self.signature = signature
    }
}

public protocol NetworkMonitoring: Sendable {
    func updates() -> AsyncStream<NetworkPathStatus>
}

/// `NWPathMonitor` (CONN-02 step 1).
public struct PathMonitor: NetworkMonitoring {
    public init() {}

    public func updates() -> AsyncStream<NetworkPathStatus> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
                let gateways = path.gateways.map { "\($0)" }.joined(separator: ",")
                continuation.yield(NetworkPathStatus(satisfied: path.status == .satisfied,
                                                     signature: "\(interfaces)|\(gateways)"))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "app.handlive.path"))
        }
    }
}
