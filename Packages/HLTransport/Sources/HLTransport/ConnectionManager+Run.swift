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
            case .connectingLAN, .connectingRelay, .waitingPeer, .handshaking: apply(.connectionLost)
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
        let hints = (try? DiscoveryHint.acceptedHints(prk: phone.pair.prk, nowMs: HLUUID.currentTimeMs())) ?? []
        let deadline = ContinuousClock.now.advanced(by: configuration.lanDiscoveryGrace)
        if await tryFastPath(phone) { return }
        var tried = Set<String>()
        var mismatched = Set<String>()
        while machine.state == .discovering && !Task.isCancelled {
            let matching = discovered.filter {
                $0.speaksProtocolV1 && DiscoveryHint.matches(txtValue: $0.hints, accepted: hints)
            }
            if let candidate = matching.first(where: { !tried.contains($0.name) }) {
                tried.insert(candidate.name)
                apply(.lanInstanceFound)
                let result = await connect(.service(candidate.endpoint), phone: phone,
                                           timeout: configuration.connectTimeout, fastPath: false)
                if result == .pinMismatch { mismatched.insert(candidate.name) }
                let allMismatched = matching.allSatisfy { mismatched.contains($0.name) }
                if afterCandidate(result, allMismatched: allMismatched) { return }
                continue
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                scheduleBackoff(.backoff)
                return apply(.lanDiscoveryGraceElapsed(relayEnabled: configuration.relayAvailable))
            }
            switch await signals.next(timeout: remaining) {
            case .network? where !networkUp: return apply(.networkLost)
            case .sleep?, .phoneChanged?: return
            default: continue
            }
        }
    }

    /// `last_host` first, while mDNS browses: a stale address or a pin mismatch there is not an error (the address
    /// may now belong to another device). Returns `true` when the attempt settled the state.
    private func tryFastPath(_ phone: PairedPhone) async -> Bool {
        guard let host = phone.lastHost, let port = phone.lastPort else { return false }
        let result = await connect(.host(host, port: port), phone: phone, timeout: configuration.fastPathTimeout,
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
    private func connect(_ target: ConnectTarget, phone: PairedPhone, timeout: Duration, fastPath: Bool) async -> AttemptResult {
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
            await adopt(established, connection: connection)
        } catch {
            let failure = (error as? SessionEstablishError) ?? .protocolError
            var minProtocol: Int32?
            if case .rejected(_, let min) = failure { minProtocol = min }
            scheduleBackoff(failure.reaction, minProtocol: minProtocol)
            apply(.handshakeFailed)
            if failure.reaction == .removePair {
                removePair(failure == .rejected(.pairUnknown, minProtocol: nil) ? .unknownToPhone : .revoked)
            }
        }
        return .done
    }

    private func adopt(_ established: ControlSession, connection: ChannelConnection) async {
        session = established
        backoff.reset()
        issue = issue == .localNetworkDenied ? issue : nil
        var updated = phone
        updated?.lastHost = connection.host
        updated?.lastPort = connection.port
        phone = updated
        apply(.handshakeSucceeded)
        let capability = await established.peerCapability ?? FallbackCapability.empty
        eventSink.yield(.connected(established, LinkDetails(route: .lan, host: connection.host, port: connection.port,
                                                            peerCapability: capability)))
        workers.append(Task { [signals, eventSink] in
            for await event in established.events {
                switch event {
                case .message(let message): eventSink.yield(.message(message))
                case .capabilityUpdated(let capability): eventSink.yield(.capabilityUpdated(capability))
                case .pairRevoked: signals.post(.pairRevoked)
                case .ended(let reason): signals.post(.sessionEnded(reason))
                }
            }
        })
    }

    // MARK: - Connected (CONN-02)

    private func superviseSession() async {
        guard let current = session else { return apply(.connectionLost) }
        switch await signals.next(timeout: nil) {
        case .sessionEnded(let reason)?:
            session = nil
            eventSink.yield(.disconnected)
            scheduleBackoff(reason.reaction)
            apply(.connectionLost)
            if reason.reaction == .removePair { removePair(.revokedByPhone) }
        case .pairRevoked?:
            session = nil
            await current.close(bye: .revoked) // PAIR-03 API 1 logic 2: ack sent, now bye + close 1000
            eventSink.yield(.disconnected)
            removePair(.revokedByPhone)
        case .network? where !networkUp:
            session = nil
            await current.close(bye: nil)
            eventSink.yield(.disconnected)
            apply(.networkLost)
        case .network?:
            // The default network changed: a dead socket would take up to 25 s to notice; probe it now.
            await current.probe(timeout: .seconds(2))
        default:
            break
        }
    }

    private func removePair(_ removal: PairRemoval) {
        phone = nil
        eventSink.yield(.pairRemoved(removal))
        apply(.unpaired)
    }
}

/// Capability placeholder used only if a session reports none (it always does after the handshake).
enum FallbackCapability {
    static let empty = CapabilityData(appVersion: "", platform: .unrecognized, osVersion: "", model: "", features: Features())
}
