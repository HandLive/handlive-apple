import Foundation
import HLCrypto
import HLProtocol

extension ConnectionManager {
    // MARK: - Connecting through the relay (CONN-03 steps 3–9)

    func connectRelay() async {
        guard let phone, let relay, relayUsable else {
            scheduleBackoff(.backoff)
            return apply(.relayFailed)
        }
        do {
            let link = try await openRelay(relay)
            if let registration = phone.relayRegistration { await registerPair(registration, relay) }
            switch await firstPresence(of: phone, on: link) {
            case .online: await handshakeOverRelay(link, phone: phone)
            case .offline:
                apply(.relayConnectedPeerOffline)
                await sendWake(.userOpen)
            case .interrupted: return
            }
        } catch {
            await closeRelay()
            relayFailed(error)
        }
    }

    /// Registers when the relay does not know this device, fetches a JWT and opens `/v1/relay` (steps 3–5).
    private func openRelay(_ relay: RelayServices) async throws -> RelayLink {
        if let link = relayLink, !(await link.isClosed) { return link }
        let token = try await relay.api.accessToken()
        let socket = try await relay.sockets.open(token: token, timeout: configuration.connectTimeout)
        let link = RelayLink(socket: socket, pingInterval: configuration.session.pingInterval,
                             pongTimeout: configuration.session.pongTimeout)
        relayLink = link
        watchRelay(link)
        await link.start()
        return link
    }

    private enum PresenceAnswer { case online, offline, interrupted }

    /// The relay sends `presence` of every pair right after connecting (step 6); no answer counts as offline.
    private func firstPresence(of phone: PairedPhone, on link: RelayLink) async -> PresenceAnswer {
        let deadline = ContinuousClock.now.advanced(by: configuration.presenceWait)
        while true {
            if let online = await link.presence(pairId: phone.pair.pairId) { return online ? .online : .offline }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return .offline }
            switch await signals.next(timeout: remaining) {
            case .relay(.closed)?:
                relayLink = nil
                scheduleBackoff(.backoff)
                apply(.relayFailed)
                return .interrupted
            case .network? where !networkUp:
                await closeRelay()
                apply(.networkLost)
                return .interrupted
            case .sleep?:
                await closeRelay()
                scheduleBackoff(.backoff)
                apply(.relayFailed)
                return .interrupted
            case .relay(.pairRevoked(let pairId, _))? where pairId == phone.pair.pairId:
                await closeRelay()
                removePair(.revokedByPhone)
                return .interrupted
            default:
                continue
            }
        }
    }

    /// `session/hello` wrapped for the relay (step 9); a phone that vanishes meanwhile sends us back to waiting (E8).
    func handshakeOverRelay(_ link: RelayLink, phone: PairedPhone) async {
        apply(.peerOnline)
        let channel = await link.channel(to: phone.pair.serverDeviceId)
        do {
            let established = try await ControlSession.establish(
                over: channel, pair: phone.pair, localCapability: localCapability, route: .relay,
                configuration: configuration.session)
            await adopt(established, host: nil, port: nil)
        } catch {
            let failure = error as? SessionEstablishError
            if failure == .closed(nil) || failure == .timedOut, !(await link.isClosed) {
                return apply(.peerOffline)
            }
            await closeRelay()
            handshakeFailed(error)
        }
    }

    // MARK: - Waiting for the phone (WaitingPeer)

    func waitForPeer() async {
        guard let phone, let link = relayLink, !(await link.isClosed) else {
            scheduleBackoff(.backoff)
            return apply(.relayConnectionLost)
        }
        if await link.presence(pairId: phone.pair.pairId) == true { return await handshakeOverRelay(link, phone: phone) }
        switch await signals.next(timeout: configuration.wakeInterval) {
        case nil, .reconnectNow?:
            await sendWake(.userOpen) // E5: again after five minutes at the earliest
        case .relay(let event)?:
            await relayEventWhileWaiting(event, link: link, phone: phone)
        case .network?:
            await networkChangedWhileWaiting(link)
        case .phoneChanged?:
            if let registration = self.phone?.relayRegistration, let relay { await registerPair(registration, relay) }
        case let signal?:
            await leaveWaitingIfNeeded(after: signal)
        }
    }

    /// Sleep, the relay turned off, or the phone back on the LAN (then Discovering finds it there).
    private func leaveWaitingIfNeeded(after signal: ManagerSignal) async {
        switch signal {
        case .sleep: await leaveWaiting(to: .relayConnectionLost)
        case .relaySettingChanged where !relayUsable: await leaveWaiting(to: .relayConnectionLost)
        case .discovery where !matchingCandidates().isEmpty: await leaveWaiting(to: .lanAvailable)
        default: break
        }
    }

    private func relayEventWhileWaiting(_ event: RelayLinkEvent, link: RelayLink, phone: PairedPhone) async {
        switch event {
        case .presence(let pairId, _, true) where pairId == phone.pair.pairId:
            await handshakeOverRelay(link, phone: phone)
        case .closed:
            await leaveWaiting(to: .relayConnectionLost)
        case .pairRevoked(let pairId, _) where pairId == phone.pair.pairId:
            await closeRelay()
            removePair(.revokedByPhone)
        case .error(.notPaired, _):
            await checkPairOnRelay()
        default:
            break
        }
    }

    private func networkChangedWhileWaiting(_ link: RelayLink) async {
        guard networkUp else {
            await closeRelay()
            return apply(.networkLost)
        }
        if (try? await link.pingSocket(timeout: .seconds(2))) == nil { await leaveWaiting(to: .relayConnectionLost) }
    }

    private func leaveWaiting(to event: ConnectionEvent) async {
        await closeRelay()
        if event == .relayConnectionLost { scheduleBackoff(.backoff) }
        apply(event)
    }

    // MARK: - Relay helpers

    /// CONN-03 E1, E3, E6, E7.
    private func relayFailed(_ error: Error) {
        switch error {
        case RelayAPIError.pinMismatch, RelayTransportError.pinMismatch:
            issue = .relayUntrusted
            scheduleBackoff(.backoff)
        case let failure as RelayAPIError where failure.isDeviceRevoked:
            issue = .relayDeviceRemoved
            relayEnabled = false
            eventSink.yield(.relayDeviceRevoked)
            scheduleBackoff(.backoff)
        case RelayAPIError.http(429, _, let retryAfter):
            issue = .relayRateLimited
            pendingDelay = .seconds(max(retryAfter ?? 0, backoff.nextDelay()) * configuration.delayScale)
        default:
            scheduleBackoff(.backoff)
        }
        apply(.relayFailed)
    }

    /// `wake` push to the phone (CONN-04 step 5a), at most once per `wakeInterval` for the same reason; a missing push
    /// token or a relay error only means the phone wakes up later by itself.
    func sendWake(_ reason: RelayPushRequest.Reason) async {
        guard let phone, let relay else { return }
        let now = ContinuousClock.now
        if let last = lastWake[reason], last.duration(to: now) < configuration.wakeInterval { return }
        lastWake[reason] = now
        let request = RelayPushRequest(pairId: phone.pair.pairId, to: phone.pair.serverDeviceId, kind: .wake,
                                       reason: reason)
        do {
            try await relay.api.push(request)
        } catch RelayAPIError.http(403, _, _) {
            await checkPairOnRelay()
        } catch {
            return
        }
    }

    /// Relay turned off here: the session through it ends with `session/bye {shutdown}` (SET-02 step 6).
    func leaveRelay() async {
        if let current = session, current.route == .relay { await current.close(bye: .shutdown) }
        await closeRelay()
    }

    func closeRelay() async {
        guard let link = relayLink else { return }
        relayLink = nil
        await link.close()
    }
}
