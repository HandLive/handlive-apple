import Foundation

/// A text frame received on `wss://{RELAY_HOST}/v1/relay` (0.4.3, 0.7.3).
public enum RelayInbound: Sendable, Equatable {
    /// `{"from": <device_id>, "env": {…}}`: an envelope forwarded from a paired device (CONN-03 API 6).
    case forward(from: String, envelope: Envelope)
    case control(RelayControl)
}

/// Relay control messages, `{"op": <name>, …}` (0.7.3, CONN-03 API 5, PAIR-01 API 7, PAIR-03 API 4).
public enum RelayControl: Sendable, Equatable {
    case presence(pairId: String, peerDeviceId: String, online: Bool)
    case error(code: RelayErrorCode, message: String, to: String?)
    case rendezvousJoined(rvId: String, peerPresent: Bool)
    case rendezvousMessage(rvId: String, envelope: Envelope)
    case pairRevoked(pairId: String, by: String)
    /// A control op this version does not know: ignored (0.5.1 rule 6).
    case unknown(op: String)
}

/// `code` of the relay `error` op (CONN-03 API 5).
public enum RelayErrorCode: String, Codable, Sendable, LenientStringEnum {
    case notPaired = "NOT_PAIRED"
    case notConnected = "NOT_CONNECTED"
    case payloadTooLarge = "PAYLOAD_TOO_LARGE"
    case rateLimited = "RATE_LIMITED"
    case badRequest = "BAD_REQUEST"
    case unrecognized = ""
}

/// Builds and parses the relay's text frames. Every value written into a frame is a UUID, b64u or an envelope whose
/// fields are ASCII-safe (0.5.1), so frames are built without a JSON encoder, like `Envelope.wireString()`.
public enum RelayFrame {
    /// A relay frame carries one envelope (≤ 256 KiB) plus the small routing wrapper.
    public static let maxFrameBytes = Envelope.maxWireBytes + 1024

    /// Device → relay: `{"to":"<device_id>","env":{<envelope>}}`.
    public static func forward(to deviceId: String, envelope: Envelope) throws -> String {
        guard HLUUID.isCanonical(deviceId) else { throw ProtocolError.invalidField("to") }
        return "{\"to\":\"\(deviceId)\",\"env\":\(envelope.wireString())}"
    }

    /// `{"op":"rv_join","rv_id":"<b64u>"}` — joins the pairing rendezvous (PAIR-01 API 7).
    public static func rendezvousJoin(rvId: String) throws -> String {
        try checkRendezvousId(rvId)
        return "{\"op\":\"rv_join\",\"rv_id\":\"\(rvId)\"}"
    }

    /// `{"op":"rv_msg","rv_id":"<b64u>","env":{<pair envelope>}}`.
    public static func rendezvousMessage(rvId: String, envelope: Envelope) throws -> String {
        try checkRendezvousId(rvId)
        return "{\"op\":\"rv_msg\",\"rv_id\":\"\(rvId)\",\"env\":\(envelope.wireString())}"
    }

    public static func parse(_ text: String) throws -> RelayInbound {
        let data = Data(text.utf8)
        guard data.count <= maxFrameBytes else { throw ProtocolError.payloadTooLarge(data.count) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProtocolError.invalidJSON
        }
        if let from = object["from"] as? String {
            guard HLUUID.isCanonical(from) else { throw ProtocolError.invalidField("from") }
            return .forward(from: from, envelope: try envelope(in: object))
        }
        guard let op = object["op"] as? String else { throw ProtocolError.missingField("op") }
        return .control(try control(op, object))
    }

    private static func control(_ op: String, _ object: [String: Any]) throws -> RelayControl {
        switch op {
        case "presence":
            return .presence(pairId: try uuid("pair_id", object), peerDeviceId: try uuid("peer_device_id", object),
                             online: try bool("online", object))
        case "error":
            let code = RelayErrorCode(rawValue: object["code"] as? String ?? "") ?? .unrecognized
            let to = (object["to"] as? String).flatMap { HLUUID.isCanonical($0) ? $0 : nil }
            return .error(code: code, message: object["message"] as? String ?? "", to: to)
        case "rv_joined":
            return .rendezvousJoined(rvId: try string("rv_id", object), peerPresent: try bool("peer_present", object))
        case "rv_msg":
            return .rendezvousMessage(rvId: try string("rv_id", object), envelope: try envelope(in: object))
        case "pair_revoked":
            return .pairRevoked(pairId: try uuid("pair_id", object), by: try uuid("by", object))
        default:
            return .unknown(op: op)
        }
    }

    private static func envelope(in object: [String: Any]) throws -> Envelope {
        guard let env = object["env"] as? [String: Any] else { throw ProtocolError.missingField("env") }
        return try Envelope.parse(object: env)
    }

    private static func string(_ key: String, _ object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else { throw ProtocolError.missingField(key) }
        return value
    }

    private static func uuid(_ key: String, _ object: [String: Any]) throws -> String {
        let value = try string(key, object)
        guard HLUUID.isCanonical(value) else { throw ProtocolError.invalidField(key) }
        return value
    }

    private static func bool(_ key: String, _ object: [String: Any]) throws -> Bool {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ProtocolError.invalidField(key)
        }
        return number.boolValue
    }

    /// `rv_id` is the b64u of 16 bytes (PAIR-01 API 1).
    private static func checkRendezvousId(_ rvId: String) throws {
        guard (try? Base64Coding.decodeB64u(rvId))?.count == 16 else { throw ProtocolError.invalidField("rv_id") }
    }
}

/// Binary frame through the relay (0.4.3): `"HR"` ‖ `ver` (1) ‖ `op` (1, `0x01` = forward) ‖ destination or source
/// `device_id` (16) ‖ the intact HL frame (0.5.2).
public struct HRFrame: Equatable, Sendable {
    public static let magic: [UInt8] = [0x48, 0x52]
    public static let version: UInt8 = 0x01
    public static let forwardOp: UInt8 = 0x01
    public static let headerByteCount = 20

    public let deviceId: String
    public let hlFrame: Data

    public init(deviceId: String, hlFrame: Data) {
        self.deviceId = deviceId
        self.hlFrame = hlFrame
    }

    public func encoded() throws -> Data {
        Data(Self.magic) + Data([Self.version, Self.forwardOp]) + (try HLUUID.bytes(from: deviceId)) + hlFrame
    }

    public static func parse(_ data: Data) throws -> HRFrame {
        let bytes = [UInt8](data)
        guard bytes.count > headerByteCount else { throw ProtocolError.invalidFrame("length") }
        guard Array(bytes[0..<2]) == magic else { throw ProtocolError.invalidFrame("magic") }
        guard bytes[2] == version else { throw ProtocolError.invalidFrame("ver") }
        guard bytes[3] == forwardOp else { throw ProtocolError.invalidFrame("op") }
        let inner = Data(bytes[headerByteCount...])
        guard Array(inner.prefix(2)) == HLFrameHeader.magic else { throw ProtocolError.invalidFrame("inner magic") }
        return HRFrame(deviceId: HLUUID.string(from: Data(bytes[4..<headerByteCount])), hlFrame: inner)
    }
}
