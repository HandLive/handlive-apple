import Foundation
import HLCrypto
import HLProtocol

extension ControlSession {
    /// `session/hello` → `session/welcome` (or `session/error`) → `capability/hello` both ways, all within
    /// `HANDSHAKE_TIMEOUT` (0.6.3, CONN-01 steps 6–9).
    func handshake(localCapability: CapabilityData) async throws {
        let timeout = HandshakeTimer()
        let timer = Task { [channel, limit = configuration.handshakeTimeout] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            timeout.fire()
            await channel.close(code: .handshakeTimeout)
        }
        defer { timer.cancel() }
        do {
            let handshake = try ClientSessionHandshake(context: pair)
            try await channel.send(.text(try handshake.helloEnvelope().wireString()))
            let keys = try handshake.handleResponse(try await receiveEnvelope())
            cipher = SessionCipher(keys: keys, now: .now)
            try await send(.capability, op: CapabilityOp.hello.rawValue, data: localCapability)
            peerCapability = try firstCapability(try await receiveEnvelope())
        } catch {
            let failure = timeout.fired ? .timedOut : Self.establishError(error)
            switch failure {
            case .authFailed: await channel.close(code: .authFailed)
            case .protocolError: await channel.close(code: .badRequest)
            case .rejected, .closed, .timedOut: await channel.close(code: .normal)
            }
            ending = .local(.normal)
            eventSink.finish()
            throw failure
        }
    }

    /// Next text frame as an envelope; binary frames do not belong on `/v1/ctl`.
    private func receiveEnvelope() async throws -> Envelope {
        while true {
            guard case .text(let text) = try await channel.receive() else { continue }
            guard let envelope = try? Envelope.parse(Data(text.utf8)) else {
                throw SessionEstablishError.protocolError
            }
            return envelope
        }
    }

    /// The phone's first encrypted envelope must be `capability/hello` (0.6.3 step 4).
    private func firstCapability(_ envelope: Envelope) throws -> CapabilityData {
        guard envelope.type == .capability, let plaintext = try? cipher?.open(envelope, now: .now),
              let payload = try? Payload.parse(plaintext), payload.op == CapabilityOp.hello.rawValue,
              let capability = try? payload.decodeData(as: CapabilityData.self)
        else { throw SessionEstablishError.protocolError }
        _ = recentIDs.check(envelope.id, now: .now)
        return capability
    }

    static func establishError(_ error: Error) -> SessionEstablishError {
        switch error {
        case let failure as SessionEstablishError:
            return failure
        case HandshakeFailure.rejected(let data):
            return .rejected(data.code, minProtocol: data.minProtocol)
        case HandshakeFailure.authFailed, HandshakeFailure.deviceMismatch:
            return .authFailed
        case let closed as ChannelClosed:
            return .closed(closed.local ? nil : closed.code)
        default:
            return .protocolError
        }
    }
}

/// Records whether the handshake timer fired before the handshake finished.
private final class HandshakeTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFire
    }

    func fire() {
        lock.lock()
        didFire = true
        lock.unlock()
    }
}
