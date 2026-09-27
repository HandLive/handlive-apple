import Foundation
import HLCalls
import HLProtocol
import HLSMS
import HLTransport

extension DevLink {
    /// Decodes the phone's `call_event/state`, `log_new`, `sms/new` and `sms/status` for the event log and prints them
    /// with their latency from the envelope `ts`; numbers keep two digits, names one letter, texts only their length.
    func record(_ envelope: IncomingEnvelope) {
        guard case .json(let payload) = envelope.body else { return }
        switch envelope.type {
        case .callEvent: recordCall(payload, ts: envelope.ts)
        case .sms: recordSms(payload, ts: envelope.ts)
        default:
            if verbose {
                DevConsole.line("\(envelope.type.rawValue)/\(payload.op) — \(DevConsole.latency(since: envelope.ts))")
            }
        }
    }

    private func recordCall(_ payload: Payload, ts: Int64) {
        switch payload.op {
        case CallEventOp.state.rawValue:
            guard let state = try? payload.decodeData(as: CallStateData.self) else { return }
            log.append(.callState(state, envelopeTs: ts))
            show("call_event/state", Self.describe(state), ts)
        case CallEventOp.logNew.rawValue:
            guard let new = try? payload.decodeData(as: CallLogNewData.self) else { return }
            log.append(.logNew(new, envelopeTs: ts))
            show("call_event/log_new", "entry \(new.entry.entryId) \(new.entry.type.rawValue) "
                + "number \(DevConsole.number(new.entry.number)) call \(new.callId.map(Self.short) ?? "none")", ts)
        default:
            if verbose { DevConsole.line("call_event/\(payload.op) — \(DevConsole.latency(since: ts))") }
        }
    }

    private func recordSms(_ payload: Payload, ts: Int64) {
        switch payload.op {
        case SmsOp.new.rawValue:
            guard let new = try? payload.decodeData(as: SmsNewData.self) else { return }
            log.append(.smsNew(new, envelopeTs: ts))
            show("sms/new", "thread \(new.message.threadId) \(new.message.box.rawValue) from "
                + "\(DevConsole.number(new.message.address)), \(new.message.body.count) characters", ts)
        case SmsOp.status.rawValue:
            guard let status = try? payload.decodeData(as: SmsStatusData.self) else { return }
            log.append(.smsStatus(status, envelopeTs: ts))
            show("sms/status", "local \(Self.short(status.localId)) \(status.status.rawValue)"
                + (status.errorCode.map { " \($0.rawValue)" } ?? ""), ts)
        default:
            if verbose { DevConsole.line("sms/\(payload.op) — \(DevConsole.latency(since: ts))") }
        }
    }

    private func show(_ kind: String, _ detail: String, _ ts: Int64) {
        guard verbose else { return }
        DevConsole.line("\(kind) \(detail) — \(DevConsole.latency(since: ts))")
    }

    static func describe(_ state: CallStateData) -> String {
        var parts = ["call \(short(state.callId))", state.state.rawValue]
        if state.waiting { parts.append("waiting") }
        parts.append("\(state.direction.rawValue) number \(DevConsole.number(state.number))")
        parts.append("name \(DevConsole.name(state.displayName))")
        if let reason = state.endReason { parts.append("end \(reason.rawValue)") }
        let controls = state.controls
        let allowed = [("answer", controls.answer), ("reject", controls.reject), ("end", controls.end)]
            .filter(\.1).map(\.0)
        parts.append("controls [\(allowed.joined(separator: ","))]")
        return parts.joined(separator: " ")
    }

    /// The first 8 characters of an id, enough to tell calls and messages apart on the console.
    static func short(_ id: String) -> String {
        String(id.prefix(8))
    }
}
