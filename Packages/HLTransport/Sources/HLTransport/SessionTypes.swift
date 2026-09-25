import Foundation
import HLProtocol

/// Timings and thresholds of a session; defaults are the constants of 0.10, tests shorten them.
public struct SessionConfiguration: Sendable {
    public var handshakeTimeout = TransportConstants.handshakeTimeout
    public var requestTimeout = TransportConstants.requestTimeout
    public var pingInterval = TransportConstants.pingInterval
    public var pongTimeout = TransportConstants.pongTimeout
    public var rekeyAfterEnvelopes = TransportConstants.rekeyAfterEnvelopes
    public var rekeyAfterAge = TransportConstants.rekeyAfterAge
    public var rekeyOldKeyGrace = TransportConstants.rekeyOldKeyGrace
    public var dedupWindow = TransportConstants.dedupWindow
    public var dedupCapacity = TransportConstants.dedupCapacity
    /// Types whose messages the app handles (`.clipboard` in Phase 1); a request of any other type is
    /// answered `UNSUPPORTED_TYPE` (0.5.1 rule 3).
    public var handledTypes: Set<MessageType> = [.clipboard]

    public init() {}
}

/// An application envelope for a feature module (clipboard in Phase 1).
public struct IncomingEnvelope: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case json(Payload)
        /// Binary plaintext of `clipboard/chunk` (0.5.1).
        case binary(Data)
    }

    public let id: String
    public let type: MessageType
    public let ts: Int64
    public let body: Body

    public init(id: String, type: MessageType, ts: Int64, body: Body) {
        self.id = id
        self.type = type
        self.ts = ts
        self.body = body
    }

    /// Op of a JSON body, `chunk` for a binary one.
    public var op: String {
        switch body {
        case .json(let payload): payload.op
        case .binary: "chunk"
        }
    }
}

/// Everything a session reports while it lives.
public enum SessionEvent: Sendable, Equatable {
    case message(IncomingEnvelope)
    /// `capability/update` (SET-02 API 1): a full snapshot that replaces the stored one.
    case capabilityUpdated(CapabilityData)
    /// `pair/revoke` received and acknowledged (PAIR-03 step 6): clean the pair up.
    case pairRevoked
    case ended(SessionEnd)
}

/// Why a session ended.
public enum SessionEnd: Sendable, Equatable {
    /// WebSocket close from the phone; `nil` when the transport dropped without a close frame.
    case peerClosed(CloseCode?)
    /// `session/bye` from the phone.
    case peerBye(SessionByeData.Reason)
    /// No pong within `PONG_TIMEOUT` (CONN-02 step 3).
    case pongTimeout
    /// An envelope did not decrypt: closed 4400 (CONN-02 E5).
    case decryptFailed
    /// Rekey without a valid `ack`: closed 4410 (CONN-02 E4).
    case rekeyFailed
    /// This side ended the session (shutdown, sleep, unpairing, replaced).
    case local(CloseCode)

    public var reaction: CloseReaction {
        switch self {
        case .peerClosed(let code?): code.clientReaction
        case .peerClosed(nil), .pongTimeout, .decryptFailed, .rekeyFailed: .backoff
        case .peerBye(.revoked): .removePair
        case .peerBye(.replaced): .none
        case .peerBye: .backoff
        case .local: .none
        }
    }
}

/// Failures of `send` and `request`.
public enum SessionError: Error, Sendable, Equatable {
    /// The session is over; the caller keeps its data for the next session (QC7).
    case ended
    /// No `ack` within `REQUEST_TIMEOUT` (`TIMEOUT`, 0.5.1 rule 1).
    case timedOut
    case encoding
}

/// Why the handshake did not reach `Connected`.
public enum SessionEstablishError: Error, Sendable, Equatable {
    /// `session/error` from the phone (CONN-01 API 6).
    case rejected(ErrorCode, minProtocol: Int32?)
    /// The phone closed the channel during the handshake.
    case closed(CloseCode?)
    /// `welcome` failed its MAC or named another device: closed 4401 (CONN-01 step 8, E3).
    case authFailed
    /// `HANDSHAKE_TIMEOUT` elapsed: closed 4408 (E6).
    case timedOut
    /// Malformed or unexpected message.
    case protocolError

    public var reaction: CloseReaction {
        switch self {
        case .rejected(let code, _): code.sessionErrorReaction
        case .closed(let code?): code.clientReaction
        case .closed(nil), .timedOut, .protocolError: .backoff
        case .authFailed: .backoffAfterAuthFailure
        }
    }
}
