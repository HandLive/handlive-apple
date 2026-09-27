import Foundation
import HLCrypto
import HLProtocol

extension ConnectionManager {
    /// The manager's loop: one step per state of the 0.11 machine.
    func run() async {
        while !Task.isCancelled {
            switch machine.state {
            case .idle(let reason): await stayIdle(reason)
            case .discovering: await discover()
            case .backoff: await waitBackoff()
            case .connected: await superviseSession()
            case .connectingRelay: await connectRelay()
            case .waitingPeer: await waitForPeer()
            case .connectingLAN, .handshaking: apply(.connectionLost)
            }
        }
    }

    var networkUp: Bool { networkPath?.satisfied ?? true }

    // MARK: - Idle

    private func stayIdle(_ reason: IdleReason) async {
        if phone == nil || !networkUp || sleeping {
            if phone != nil && !networkUp { apply(.networkLost) }
            _ = await signals.next(timeout: nil)
            return
        }
        if reason == .needsRepair {
            // The phone regenerated its certificate: only the user (Reconnect Now, pairing again) retries.
            let signal = await signals.next(timeout: nil)
            guard signal == .reconnectNow || signal == .phoneChanged else { return }
        }
        apply(.pairedAndNetworkAvailable)
    }

    // MARK: - Discovering (CONN-01 steps 2–5)

    private func discover() async {
        guard let phone else { return apply(.unpaired) }
        let deadline = ContinuousClock.now.advanced(by: configuration.lanDiscoveryGrace)
        if await tryFastPath(phone) { return }
        var tried = Set<String>()
        var mismatched = Set<String>()
        while machine.state == .discovering && !Task.isCancelled {
            let matching = matchingCandidates()
            if let candidate = matching.first(where: { !tried.contains($0.name) }) {
                tried.insert(candidate.name)
                apply(.lanInstanceFound)
                let result = await connectLAN(.service(candidate.endpoint), phone: phone,
                                              timeout: configuration.connectTimeout, fastPath: false)
                if result == .pinMismatch { mismatched.insert(candidate.name) }
                let allMismatched = matching.allSatisfy { mismatched.contains($0.name) }
                if afterCandidate(result, allMismatched: allMismatched) { return }
                continue
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return graceElapsed() }
            switch await signals.next(timeout: remaining) {
            case .network? where !networkUp: return apply(.networkLost)
            case .sleep?, .phoneChanged?: return
            default: continue
            }
        }
    }

    /// `LAN_DISCOVERY_GRACE` is over: the relay when it may be used (CONN-03 step 2), otherwise `Backoff`.
    private func graceElapsed() {
        if !relayUsable { scheduleBackoff(.backoff) }
        apply(.lanDiscoveryGraceElapsed(relayEnabled: relayUsable))
    }

    /// `last_host` first, while mDNS browses: a stale address or a pin mismatch there is not an error (the address
    /// may now belong to another device). Returns `true` when the attempt settled the state.
    private func tryFastPath(_ phone: PairedPhone) async -> Bool {
        guard let host = phone.lastHost, let port = phone.lastPort else { return false }
        let result = await connectLAN(.host(host, port: port), phone: phone, timeout: configuration.fastPathTimeout,
                                      fastPath: true)
        return result == .done
    }

    /// Next step after an mDNS candidate; `true` when discovery is over.
    private func afterCandidate(_ result: AttemptResult, allMismatched: Bool) -> Bool {
        switch result {
        case .pinMismatch:
            apply(allMismatched ? .allInstancesPinMismatch : .tlsPinMismatch)
            return allMismatched
        case .unreachable:
            scheduleBackoff(.backoff)
            apply(.lanConnectFailed)
            return true
        case .done:
            return true
        }
    }

    enum AttemptResult: Equatable {
        case pinMismatch
        case unreachable
        /// Connected, or the handshake decided what comes next.
        case done
    }

    /// Pinned TLS, then the session handshake (CONN-01 steps 4–9).
    private func connectLAN(_ target: ConnectTarget, phone: PairedPhone, timeout: Duration,
                            fastPath: Bool) async -> AttemptResult {
        let connection: ChannelConnection
        do {
            connection = try await connector.connect(to: target, path: TransportConstants.controlPath,
                                                     policy: .pinned(phone.certificateSHA256), timeout: timeout)
        } catch ConnectError.pinMismatch {
            return .pinMismatch
        } catch {
            return .unreachable
        }
        if fastPath { apply(.lanInstanceFound) }
        apply(.tlsPinVerified)
        do {
            let established = try await ControlSession.establish(
                over: connection.channel, pair: phone.pair, localCapability: localCapability, route: .lan,
                configuration: configuration.session)
            await adopt(established, host: connection.host, port: connection.port)
            await closeRelay() // a LAN session never needs the relay connection
        } catch {
            handshakeFailed(error)
        }
        return .done
    }

    /// A handshake that did not reach `Connected`: backoff per its reaction, pair removal when the phone forgot it.
    func handshakeFailed(_ error: Error) {
        let failure = (error as? SessionEstablishError) ?? .protocolError
        var minProtocol: Int32?
        if case .rejected(_, let min) = failure { minProtocol = min }
        scheduleBackoff(failure.reaction, minProtocol: minProtocol)
        apply(.handshakeFailed)
        if failure.reaction == .removePair {
            removePair(failure == .rejected(.pairUnknown, minProtocol: nil) ? .unknownToPhone : .revoked)
        }
    }

    /// Makes an established session the current one (CONN-01 step 10): `Connected`, `last_host` for a LAN session, the
    /// phone's relay switch from its capability, and a watcher that reports the session's events.
    func adopt(_ established: ControlSession, host: String?, port: UInt16?) async {
        session = established
        sessionToken &+= 1
        let token = sessionToken
        backoff.reset()
        if issue != .localNetworkDenied && issue != .relayDeviceRemoved { issue = nil }
        let capability = await established.peerCapability ?? FallbackCapability.empty
        phone?.relayEnabled = capability.features.relay?.enabled ?? false
        if let host, let port {
            phone?.lastHost = host
            phone?.lastPort = port
        }
        apply(.handshakeSucceeded)
        eventSink.yield(.connected(established, LinkDetails(route: established.route, host: host, port: port,
                                                            peerCapability: capability)))
        workers.append(Task { [signals, eventSink] in
            for await event in established.events {
                switch event {
                case .message(let message): eventSink.yield(.message(message))
                case .capabilityUpdated(let capability): eventSink.yield(.capabilityUpdated(capability))
                case .pairRevoked: signals.post(.pairRevoked(token: token))
                case .ended(let reason): signals.post(.sessionEnded(reason, token: token))
                }
            }
        })
    }

    func removePair(_ removal: PairRemoval) {
        phone = nil
        eventSink.yield(.pairRemoved(removal))
        apply(.unpaired)
    }
}

/// Capability placeholder used only if a session reports none (it always does after the handshake).
enum FallbackCapability {
    static let empty = CapabilityData(appVersion: "", platform: .unrecognized, osVersion: "", model: "", features: Features())
}
