import Foundation
import HLCrypto
import HLProtocol

extension ConnectionManager {
    /// How often a session through the relay looks again for the phone on the LAN when mDNS reports nothing new.
    static let upgradeRecheck: Duration = .seconds(60)

    // MARK: - Connected (CONN-02)

    func superviseSession() async {
        guard let current = session else { return apply(.connectionLost) }
        let signal = await signals.next(timeout: current.route == .relay ? Self.upgradeRecheck : nil)
        switch signal {
        case .sessionEnded(let reason, let token)? where token == sessionToken:
            await sessionEnded(current, reason)
        case .pairRevoked(let token)? where token == sessionToken:
            session = nil
            await current.close(bye: .revoked) // PAIR-03 API 1 logic 2: ack sent, now bye + close 1000
            eventSink.yield(.disconnected)
            await closeRelay()
            removePair(.revokedByPhone)
        case .network?:
            await networkChanged(current)
        case .discovery?:
            if current.route == .relay { await upgradeToLAN(from: current) }
        case .relay(let event)?:
            await relayEventWhileConnected(event, current)
        case nil where current.route == .relay:
            upgradeTried.removeAll()
            await upgradeToLAN(from: current)
        default:
            break
        }
    }

    private func networkChanged(_ current: ControlSession) async {
        guard networkUp else {
            session = nil
            await current.close(bye: nil)
            eventSink.yield(.disconnected)
            await closeRelay()
            return apply(.networkLost)
        }
        // The default network changed: a dead socket would take up to 25 s to notice; probe it now.
        await current.probe(timeout: .seconds(2))
        if current.route == .relay { await upgradeToLAN(from: current) }
    }

    /// The current session ended. Through the relay, with the relay still up, the phone just left: wait for it there
    /// (CONN-03 E8); otherwise back off and reconnect.
    private func sessionEnded(_ current: ControlSession, _ reason: SessionEnd) async {
        session = nil
        eventSink.yield(.disconnected)
        let reaction = reason.reaction
        if current.route == .relay, reaction == .backoff || reaction == .none, relayUsable,
           let link = relayLink, !(await link.isClosed) {
            return apply(.peerOffline)
        }
        if current.route == .relay { await closeRelay() }
        scheduleBackoff(reaction)
        apply(.connectionLost)
        if reaction == .removePair { removePair(.revokedByPhone) }
    }

    private func relayEventWhileConnected(_ event: RelayLinkEvent, _ current: ControlSession) async {
        guard let phone else { return }
        switch event {
        case .pairRevoked(let pairId, _) where pairId == phone.pair.pairId:
            session = nil
            await current.close(bye: nil)
            eventSink.yield(.disconnected)
            await closeRelay()
            removePair(.revokedByPhone) // PAIR-03 API 4
        case .presence(let pairId, _, false) where pairId == phone.pair.pairId && current.route == .relay:
            _ = await current.probeEndToEnd(timeout: configuration.session.pongTimeout) // a hint, not the truth
        case .error(.notPaired, _):
            await checkPairOnRelay()
        default:
            break
        }
    }

    // MARK: - Relay → LAN (CONN-02 step 7)

    /// On the relay while mDNS shows the phone: open a LAN session next to the relay session, and switch only once it is
    /// established. The phone then retires the relay session (`session/bye {replaced}`); a failed attempt keeps the relay.
    func upgradeToLAN(from current: ControlSession) async {
        guard let phone, session === current,
              let candidate = matchingCandidates().first(where: { !upgradeTried.contains($0.name) })
        else { return }
        upgradeTried.insert(candidate.name)
        guard let connection = try? await connector.connect(
                to: .service(candidate.endpoint), path: TransportConstants.controlPath,
                policy: .pinned(phone.certificateSHA256), timeout: configuration.connectTimeout),
              let established = try? await ControlSession.establish(
                over: connection.channel, pair: phone.pair, localCapability: localCapability, route: .lan,
                configuration: configuration.session)
        else { return }
        guard session === current else {
            await established.close(bye: .shutdown)
            return
        }
        apply(.lanAvailable)
        apply(.tlsPinVerified)
        await adopt(established, host: connection.host, port: connection.port)
        // Envelopes still in flight on the relay session keep arriving until the phone retires it.
        workers.append(Task { [weak self, grace = configuration.upgradeGrace] in
            try? await Task.sleep(for: grace)
            await current.close(bye: nil)
            await self?.closeRelayUnlessUsed()
        })
    }

    /// Closes the relay connection once no session goes through it.
    func closeRelayUnlessUsed() async {
        guard session?.route != .relay, machine.state != .waitingPeer, machine.state != .connectingRelay else { return }
        await closeRelay()
    }
}
