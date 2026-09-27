import Foundation
import HLAppCore
import HLCrypto
import HLProtocol

/// What the Notification Service Extension reads from a call push (CONN-04 step 9b, CALL-01 API 6, CALL-04 API 4): `p`
/// and `hl`, the pair's `PRK`, `K_push`, the 24-hour limit, and a `call_event` inside — a ringing `state`
/// (`call_incoming`), a `log_new` of a missed call, or an idle `state` missed without the call log (flow A,
/// `call_missed`). Anything else keeps the generic content the relay sent (E6, E9).
public enum CallPushDecoder {
    public enum Content: Equatable, Sendable {
        case incoming(CallStateData)
        case missed(MissedCall)
    }

    public struct Decoded: Equatable, Sendable {
        public let pairId: String
        /// Envelope `id`, for de-duplication (CONN-04 E7).
        public let envelopeId: String
        public let content: Content
    }

    /// `prk` returns the pair's `PRK`, or `nil` when the Keychain refuses (the device is locked, C3).
    public static func decode(userInfo: [AnyHashable: Any], nowMs: Int64, prk: (String) -> Data?) -> Decoded? {
        guard let fields = PushAlertFields(userInfo: userInfo) else { return nil }
        return decode(fields: fields, nowMs: nowMs, prk: prk)
    }

    /// The same from the push's plain fields, already read from `userInfo`.
    public static func decode(fields: PushAlertFields, nowMs: Int64, prk: (String) -> Data?) -> Decoded? {
        guard fields.envelope.type == .callEvent, let key = prk(fields.pairId),
              let plaintext = try? PushEnvelope.open(fields.envelope, prk: key, nowMs: nowMs),
              let payload = try? Payload.parse(plaintext),
              let content = content(of: payload, pairId: fields.pairId)
        else { return nil }
        return Decoded(pairId: fields.pairId, envelopeId: fields.envelope.id, content: content)
    }

    static func content(of payload: Payload, pairId: String) -> Content? {
        switch CallEventOp(rawValue: payload.op) {
        case .state?:
            guard let state = try? payload.decodeData(as: CallStateData.self) else { return nil }
            if state.state == .ringing, !state.waiting { return .incoming(state) }
            guard state.state == .idle, state.endReason == .missed else { return nil }
            return .missed(MissedCall(pairId: pairId, entryId: nil, callId: state.callId, number: state.number,
                                      caller: CallerIdentity(state: state), ts: state.startedAt, subId: state.subId,
                                      simLabel: state.simLabel))
        case .logNew?:
            guard let new = try? payload.decodeData(as: CallLogNewData.self), new.entry.type == .missed else { return nil }
            // The extension cannot read the phone's SIM list, so a pushed missed call has no SIM label.
            return .missed(MissedCall(pairId: pairId, entryId: new.entry.entryId, callId: new.callId,
                                      number: new.entry.number, caller: CallerIdentity(entry: new.entry),
                                      ts: new.entry.ts, subId: new.entry.subId, simLabel: nil))
        default:
            return nil
        }
    }
}
