import Foundation
import HLProtocol
import HLTransport

/// Why a message cannot be queued (SMS-04 step 2): the UI blocks these before sending.
public enum SmsComposeError: Error, Equatable, Sendable {
    /// Empty after trimming, or more than 1,600 characters (E5).
    case invalidText
    /// Not 3–15 digits with an optional leading `+` (field 1).
    case invalidRecipient
    /// Conversation with several recipients (E9).
    case groupConversation
    /// No pair.
    case notPaired
}

extension SmsEngine {
    /// Step 2: text after trimming, non-empty, ≤ 1,600 characters (code points, 0.3 `string(n)`).
    public nonisolated static func validText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= SmsSendRequest.maxBodyCharacters else { return nil }
        return trimmed
    }

    /// Field 1: digits and an optional leading `+`, 3–15 characters (the phone normalizes and checks it properly).
    public nonisolated static func validRecipient(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace && $0 != "-" && $0 != "(" && $0 != ")" && $0 != "." }
        let digits = compact.hasPrefix("+") ? compact.dropFirst() : Substring(compact)
        guard (3...15).contains(compact.count), !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return compact
    }

    /// Steps 2–5: validate, queue as `pending` (the placeholder bubble), then send when a session exists; otherwise ask
    /// for a wake-up and wait (E1). Returns the `local_id`.
    @discardableResult
    public func send(text: String, to address: String, threadId: Int64?, subId: Int32?) async throws -> String {
        guard let pairId else { throw SmsComposeError.notPaired }
        guard let body = Self.validText(text) else { throw SmsComposeError.invalidText }
        let draft = SmsDraft(threadId: threadId, addresses: [address], body: body, subId: subId ?? defaultSubId)
        let localId = draft.localId
        BenchLog.event("sms_send_tap", ["local": localId])
        try await store.enqueue(draft, pairId: pairId, now: now())
        BenchLog.event("sms_bubble", ["local": localId]) // the database observation shows it right after this write
        if phone == nil {
            onEvent(.needsPhone)
        } else {
            startFlush()
        }
        return localId
    }

    /// Reply in a conversation (its only address; group conversations cannot be answered, E9).
    @discardableResult
    public func reply(text: String, in thread: SmsThread, subId: Int32?) async throws -> String {
        guard !thread.isGroup, let address = thread.addresses.first else { throw SmsComposeError.groupConversation }
        return try await send(text: text, to: address, threadId: thread.threadId, subId: subId)
    }

    /// A1: "Try Again" on a failed message: a new `local_id` with the same text, recipient and SIM.
    @discardableResult
    public func retry(localId: String) async throws -> String? {
        guard let entry = try await store.removeFailed(localId: localId), let address = entry.addresses.first else {
            return nil
        }
        return try await send(text: entry.body, to: address, threadId: entry.threadId, subId: entry.subId)
    }

    /// B2–B3 (iOS quick reply) and the Mac's reply action: queue, then wait up to `deadline` for the phone to accept.
    /// `false` leaves the message `pending` for the next session (E8).
    public func quickReply(text: String, to address: String, threadId: Int64, subId: Int32?,
                           deadline: Duration) async -> Bool {
        guard let localId = try? await send(text: text, to: address, threadId: threadId, subId: subId) else { return false }
        await markRead(threadId: threadId) // SMS-04 API 5 logic 5
        let end = ContinuousClock.now.advanced(by: deadline)
        while ContinuousClock.now < end {
            if let entry = try? await store.outboxEntry(localId: localId), entry.state != .pending { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: - Delivery (step 5)

    /// Sends the waiting messages one after the other, oldest first (CONN-02 step 10).
    func startFlush() {
        flushRequested = true
        guard flushTask == nil, phone != nil else { return }
        flushTask = Task { [weak self] in
            while let self, self.flushRequested {
                self.flushRequested = false
                await self.flushOutbox()
            }
            self?.flushTask = nil
        }
    }

    private func flushOutbox() async {
        while !Task.isCancelled, let pairId, phone != nil, canSend {
            guard let pending = try? await store.pending(pairId: pairId),
                  let entry = pending.first(where: { !unanswered.contains($0.localId) })
            else { return }
            guard await deliver(entry) else {
                unanswered.insert(entry.localId) // no ack after every retry: wait for the next session (E1)
                return
            }
        }
    }

    /// One message: `sms/send` with the same envelope `id` on every try, retried after 5, 15 and 45 s without an `ack`.
    /// Returns `false` when the phone never answered.
    private func deliver(_ entry: SmsOutboxEntry) async -> Bool {
        guard let peer = phone?.peer else { return false }
        let envelopeId = envelopeIds[entry.localId] ?? HLUUID.v7()
        envelopeIds[entry.localId] = envelopeId
        let request = SmsSendRequest(localId: entry.localId, threadId: entry.threadId, addresses: entry.addresses,
                                     body: entry.body, subId: entry.subId)
        for (attempt, delay) in ([Duration.zero] + retryDelays).enumerated() {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, phone != nil else { return false }
            }
            try? await store.recordAttempt(localId: entry.localId, now: now())
            BenchLog.event("sms_send_sent", ["local": entry.localId, "peer": benchPeer, "attempt": "\(attempt + 1)",
                                             "via": peer.route == .relay ? "relay" : "lan"])
            do {
                let ack = try await peer.request(.send, data: request, id: envelopeId, timeout: requestTimeout)
                var fields = [("local", entry.localId), ("peer", benchPeer), ("ok", "\(ack.ok)")]
                if let code = ack.error?.code { fields.append(("code", code.rawValue)) }
                BenchLog.event("sms_send_ack_received", fields: fields)
                let state: SmsSendState = ack.ok ? .sending : .failed // step 7, or E2–E6 with the code
                let error = ack.error?.code.rawValue
                _ = try? await store.transition(localId: entry.localId, to: state, error: error, now: now())
                envelopeIds[entry.localId] = nil
                return true
            } catch SessionError.timedOut {
                continue
            } catch {
                return false // the session ended: the message waits for the next one
            }
        }
        return false
    }
}
