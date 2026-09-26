import Foundation
import HLProtocol
import HLTransport

extension SmsEngine {
    // MARK: - SMS-02, SMS-04 API 2 and 4, SMS-05

    /// SMS-02 step 6–8: store the message and its conversation, then notify for a new inbox message (not for the
    /// conversation open in the window in use, not with `sms.notify` off).
    func applyNew(_ data: SmsNewData) async {
        guard let pairId else { return }
        guard let isNew = try? await store.applyNew(data, pairId: pairId) else { return }
        await publishBadge()
        guard isNew, data.message.box == .inbox, notifyEnabled(), openThreadId != data.thread.threadId else { return }
        onEvent(.notify(SmsIncoming(pairId: pairId, message: data.message, thread: data.thread,
                                    simLabel: simLabel(for: data.message.subId))))
    }

    /// SMS-04 API 2: forward-only status of a message sent from here (logic 2); no delivery report keeps "Sent" (E10).
    func applyStatus(_ data: SmsStatusData) async {
        let state: SmsSendState? = switch data.status {
        case .sending: .sending
        case .sent: .sent
        case .delivered: .delivered
        case .failed: .failed
        case .unrecognized: nil
        }
        guard let state else { return }
        let error = state == .failed ? (data.errorCode ?? .smsGenericFailure).rawValue : nil
        guard (try? await store.transition(localId: data.localId, to: state, error: error, now: now())) != nil else { return }
        var fields = [("local", data.localId), ("status", data.status.rawValue)]
        if let code = data.errorCode { fields.append(("code", code.rawValue)) }
        BenchLog.event("sms_status_received", fields: fields)
    }

    /// SMS-05 steps 6–7: the phone's read state; read notifications go away, the badge follows.
    func applyReadChanged(_ state: SmsReadState) async {
        guard let pairId else { return }
        guard (try? await store.applyReadState(state, pairId: pairId)) != nil else { return }
        onEvent(.removeNotifications(pairId: pairId, threadId: state.threadId, upToTs: state.readUpToTs))
        await publishBadge()
    }

    /// SMS-03 step 4 and SMS-05 A2: the conversation is read here (the phone is not told, E3), its notifications go.
    public func openConversation(threadId: Int64) async {
        openThreadId = threadId
        await markRead(threadId: threadId)
    }

    public func closeConversation(threadId: Int64) {
        if openThreadId == threadId { openThreadId = nil }
    }

    func markRead(threadId: Int64) async {
        guard let pairId else { return }
        try? await store.markLocallyRead(pairId: pairId, threadId: threadId)
        onEvent(.removeNotifications(pairId: pairId, threadId: threadId, upToTs: nil))
        await publishBadge()
    }

    /// The SIM's label when the phone has more than one SIM (SMS-02 field 3, SMS-03 field 9).
    public func simLabel(for subId: Int32?) -> String? {
        guard sims.count > 1, let subId else { return nil }
        return sims.first { $0.subId == subId }?.label
    }
}
