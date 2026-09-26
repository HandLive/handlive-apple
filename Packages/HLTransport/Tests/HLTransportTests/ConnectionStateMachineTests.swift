import HLProtocol
import Testing
@testable import HLTransport

@Suite("Connection state machine (0.11)")
struct ConnectionStateMachineTests {
    struct Edge: Sendable, CustomTestStringConvertible {
        let from: ConnectionState
        let event: ConnectionEvent
        let to: ConnectionState
        var testDescription: String { "\(from) --\(event)--> \(to)" }
    }

    /// Every edge of the 0.11 diagram, in diagram order.
    static let diagramEdges: [Edge] = [
        Edge(from: .idle(.notPaired), event: .pairedAndNetworkAvailable, to: .discovering),
        Edge(from: .discovering, event: .lanInstanceFound, to: .connectingLAN),
        Edge(from: .connectingLAN, event: .tlsPinVerified, to: .handshaking(.lan)),
        Edge(from: .connectingLAN, event: .tlsPinMismatch, to: .discovering),
        Edge(from: .handshaking(.lan), event: .handshakeSucceeded, to: .connected(.lan)),
        Edge(from: .handshaking(.relay), event: .handshakeSucceeded, to: .connected(.relay)),
        Edge(from: .handshaking(.lan), event: .handshakeFailed, to: .backoff),
        Edge(from: .connectingLAN, event: .lanConnectFailed, to: .backoff),
        Edge(from: .connectingLAN, event: .allInstancesPinMismatch, to: .idle(.needsRepair)),
        Edge(from: .connectingRelay, event: .relayFailed, to: .backoff),
        Edge(from: .waitingPeer, event: .relayConnectionLost, to: .backoff),
        Edge(from: .discovering, event: .lanDiscoveryGraceElapsed(relayEnabled: false), to: .backoff),
        Edge(from: .discovering, event: .unpaired, to: .idle(.notPaired)),
        Edge(from: .backoff, event: .unpaired, to: .idle(.notPaired)),
        Edge(from: .discovering, event: .lanDiscoveryGraceElapsed(relayEnabled: true), to: .connectingRelay),
        Edge(from: .connectingRelay, event: .relayConnectedPeerOffline, to: .waitingPeer),
        Edge(from: .waitingPeer, event: .peerOnline, to: .handshaking(.relay)),
        Edge(from: .connectingRelay, event: .peerOnline, to: .handshaking(.relay)),
        Edge(from: .connected(.lan), event: .connectionLost, to: .backoff),
        Edge(from: .connected(.relay), event: .lanAvailable, to: .connectingLAN),
        Edge(from: .backoff, event: .backoffElapsed, to: .discovering),
        Edge(from: .backoff, event: .networkChanged, to: .discovering),
        Edge(from: .connected(.lan), event: .unpaired, to: .idle(.notPaired)),
    ]

    /// Edges the diagram leaves implicit: CONN-02 E1 (no network → Idle) and unpairing mid-attempt.
    static let implicitEdges: [Edge] = [
        Edge(from: .connected(.lan), event: .networkLost, to: .idle(.noNetwork)),
        Edge(from: .backoff, event: .networkLost, to: .idle(.noNetwork)),
        Edge(from: .handshaking(.lan), event: .networkLost, to: .idle(.noNetwork)),
        Edge(from: .idle(.noNetwork), event: .pairedAndNetworkAvailable, to: .discovering),
        Edge(from: .idle(.needsRepair), event: .pairedAndNetworkAvailable, to: .discovering),
        Edge(from: .handshaking(.lan), event: .unpaired, to: .idle(.notPaired)),
        Edge(from: .connectingLAN, event: .unpaired, to: .idle(.notPaired)),
        Edge(from: .idle(.needsRepair), event: .unpaired, to: .idle(.notPaired)),
    ]

    @Test("Every edge of the diagram", arguments: diagramEdges)
    func diagramEdge(_ edge: Edge) {
        var machine = ConnectionStateMachine(state: edge.from)
        let changed = machine.handle(edge.event)
        #expect(changed)
        #expect(machine.state == edge.to)
    }

    @Test("Edges implied by CONN-02 E1 and PAIR-03", arguments: implicitEdges)
    func implicitEdge(_ edge: Edge) {
        var machine = ConnectionStateMachine(state: edge.from)
        let changed = machine.handle(edge.event)
        #expect(changed)
        #expect(machine.state == edge.to)
    }

    @Test("Events without an edge leave the state unchanged")
    func ignoredEvents() {
        let ignored: [(ConnectionState, ConnectionEvent)] = [
            (.idle(.notPaired), .handshakeSucceeded),
            (.idle(.notPaired), .networkLost),
            (.idle(.needsRepair), .networkLost),
            (.idle(.noNetwork), .networkLost),
            (.connected(.lan), .lanAvailable),
            (.waitingPeer, .connectionLost),
            (.backoff, .peerOnline),
            (.discovering, .tlsPinMismatch),
            (.handshaking(.relay), .relayFailed),
            (.idle(.notPaired), .unpaired),
        ]
        for (state, event) in ignored {
            var machine = ConnectionStateMachine(state: state)
            let changed = machine.handle(event)
            #expect(!changed, "\(state) \(event)")
            #expect(machine.state == state)
        }
    }

    @Test("Scenario: relay when the LAN is silent, then upgrade to the LAN")
    func relayThenLanUpgrade() {
        var machine = ConnectionStateMachine()
        let events: [ConnectionEvent] = [
            .pairedAndNetworkAvailable, .lanDiscoveryGraceElapsed(relayEnabled: true), .relayConnectedPeerOffline,
            .peerOnline, .handshakeSucceeded, .lanAvailable, .tlsPinVerified, .handshakeSucceeded,
        ]
        var statuses: [ConnectionStatus] = []
        for event in events {
            let changed = machine.handle(event)
            #expect(changed)
            statuses.append(ConnectionStatus(machine.state))
        }
        #expect(machine.state == .connected(.lan))
        #expect(statuses.contains(.phoneOffline))
        #expect(statuses.contains(.connected(.relay)))
    }

    @Test("Scenario: the phone regenerated its TLS key — stop at Needs re-pairing")
    func pinMismatchEverywhere() {
        var machine = ConnectionStateMachine()
        let events: [ConnectionEvent] = [
            .pairedAndNetworkAvailable, .lanInstanceFound, .tlsPinMismatch, .lanInstanceFound,
            .allInstancesPinMismatch,
        ]
        for event in events { machine.handle(event) }
        #expect(machine.state == .idle(.needsRepair))
        #expect(ConnectionStatus(machine.state) == .needsRepair)
    }

    @Test("Displayed status (PAIR-02, 0.11)")
    func displayStatus() {
        #expect(ConnectionStatus(.idle(.notPaired)) == .notPaired)
        #expect(ConnectionStatus(.idle(.noNetwork)) == .disconnected)
        #expect(ConnectionStatus(.idle(.needsRepair)) == .needsRepair)
        #expect(ConnectionStatus(.backoff) == .disconnected)
        #expect(ConnectionStatus(.discovering) == .connecting)
        #expect(ConnectionStatus(.handshaking(.relay)) == .connecting)
        #expect(ConnectionStatus(.connectingRelay) == .connecting)
        #expect(ConnectionStatus(.waitingPeer) == .phoneOffline)
        #expect(ConnectionStatus(.connected(.lan)) == .connected(.lan))
        #expect(ConnectionStatus(.connected(.relay)) == .connected(.relay))
    }

    @Test("Client reaction to close codes 4401, 4403, 4409, 4410, 4411, 4426, 4429")
    func closeReactions() {
        #expect(CloseCode.authFailed.clientReaction == .backoffAfterAuthFailure)
        #expect(CloseCode.pairRevoked.clientReaction == .removePair)
        #expect(CloseCode.replaced.clientReaction == CloseReaction.none)
        #expect(CloseCode.rekeyFailed.clientReaction == .backoff)
        #expect(CloseCode.idleTimeout.clientReaction == .backoff)
        #expect(CloseCode.unsupportedVersion.clientReaction == .updateRequired)
        #expect(CloseCode.rateLimited.clientReaction == .backoff)
        #expect(CloseCode.handshakeTimeout.clientReaction == .backoff)
        #expect(CloseCode.other(4999).clientReaction == .backoff)
        #expect(ErrorCode.pairUnknown.sessionErrorReaction == .removePair)
        #expect(ErrorCode.pairRevoked.sessionErrorReaction == .removePair)
        #expect(ErrorCode.authFailed.sessionErrorReaction == .backoffAfterAuthFailure)
        #expect(ErrorCode.unsupportedVersion.sessionErrorReaction == .updateRequired)
        #expect(ErrorCode.rateLimited.sessionErrorReaction == .backoff)
    }

    @Test("RECONNECT_BACKOFF 0.5 → 30 s, jitter ±20 %, reset; AUTH_FAILED waits 5 minutes")
    func backoff() {
        var backoff = ReconnectBackoff()
        let delays = (0..<9).map { _ in backoff.nextDelay(unitRandom: 0) }
        #expect(delays == [0.5, 1, 2, 4, 8, 16, 30, 30, 30])
        let high = backoff.nextDelay(unitRandom: 1)
        let low = backoff.nextDelay(unitRandom: -1)
        #expect(high == 36)
        #expect(low == 24)
        backoff.reset()
        let first = backoff.nextDelay(unitRandom: 0)
        #expect(first == 0.5)
        for _ in 0..<50 {
            let delay = backoff.nextDelay()
            #expect(delay >= 0.4 && delay <= 36)
        }
        #expect(ReconnectBackoff.authFailedDelay == 300)
    }
}
