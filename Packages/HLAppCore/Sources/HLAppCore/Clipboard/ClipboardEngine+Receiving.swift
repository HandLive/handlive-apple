import Foundation
import HLProtocol
import HLTransport

extension ClipboardEngine {
    /// A `clipboard` envelope of the current session.
    public func receive(_ envelope: IncomingEnvelope) {
        switch envelope.body {
        case .binary(let plaintext):
            receiveChunk(plaintext)
        case .json(let payload):
            switch ClipboardOp(rawValue: payload.op) {
            case .push: receivePush(payload, requestId: envelope.id)
            case .cancel: (try? payload.decodeData(as: ClipboardCancelData.self)).map(receiveCancel)
            case .conflict: (try? payload.decodeData(as: ClipboardConflictData.self)).map(receiveConflict)
            case .chunk, nil: break
            }
        }
    }

    // MARK: - clipboard/push (CLIP-01 API 5 logic 5–8, CLIP-03 API 3)

    private func receivePush(_ payload: Payload, requestId: String) {
        guard let phone else { return }
        guard let push = try? payload.decodeData(as: ClipboardPushData.self) else {
            reply(requestId, .rejected(.badRequest, clipId: nil))
            return
        }
        let bytes = push.text.map { $0.utf8.count } ?? Int(push.transfer?.size ?? 0)
        BenchLog.event("clip_received", ["clip": push.clipId, "peer": Self.benchId(phone.deviceId),
                                         "kind": push.kind.rawValue, "bytes": String(bytes)])
        if let code = validate(push) {
            ledger.record(push.clipId, .rejected, now: now())
            reply(requestId, .rejected(code, clipId: push.clipId))
            return
        }
        if ledger.isDuplicate(push.clipId, now: now()) {
            reply(requestId, .ignored(push.clipId, .duplicate))
            return
        }
        // One incoming transfer per peer: any newer push replaces it (CLIP-03 API 3 logic 2).
        if let old = incoming {
            endIncoming()
            reply(old.requestId, .ignored(old.push.clipId, .cancelled))
        }
        if let transfer = push.transfer {
            startIncoming(push, transfer: transfer, requestId: requestId)
        } else if let text = push.text {
            apply(.text(text), push: push, requestId: requestId)
        }
    }

    /// `kind` matches `mime`, exactly one of `text`/`transfer`, clipboard on, within this Mac's limits and MIME types.
    func validate(_ push: ClipboardPushData) -> ErrorCode? {
        let imageMimes = [ClipMime.png, ClipMime.jpeg]
        let kindMatches = push.kind == .text ? push.mime == ClipMime.text : imageMimes.contains(push.mime)
        guard HLUUID.isCanonical(push.clipId), kindMatches, (push.text == nil) != (push.transfer == nil),
              push.kind == .text || push.transfer != nil
        else { return .badRequest }
        guard settings.clipboardEnabled else { return .featureDisabled }
        if push.kind == .image, !settings.sendImages { return .clipUnsupportedMime }
        let limit = push.kind == .text ? ClipboardConstants.maxTextBytes : ClipboardConstants.maxImageBytes
        if let text = push.text { return text.utf8.count > limit ? .clipTooLarge : nil }
        guard let transfer = push.transfer else { return .badRequest }
        guard transfer.size <= Int64(limit) else { return .clipTooLarge }
        let chunkSize = Int64(ClipboardConstants.chunkSize)
        guard transfer.size > 0, transfer.chunkSize == Int32(chunkSize),
              Int64(transfer.chunkCount) == (transfer.size + chunkSize - 1) / chunkSize,
              HLUUID.isValid(transfer.transferId, version: 7),
              (try? Base64Coding.decodeB64u(transfer.sha256))?.count == 32
        else { return .badRequest }
        return nil
    }

    /// QC8, then the write (CLIP-01 API 7, CLIP-03 API 7), the QC4 trace, CLIP-05 and the `ack`.
    func apply(_ content: ClipContent, push: ClipboardPushData, requestId: String) {
        noticeUnseenLocalChange()
        switch ConflictPolicy.decide(originTs: push.originTs, originDeviceId: push.originDeviceId,
                                     local: unacknowledgedLocalChange(), now: now()) {
        case .keepLocalAndReport:
            ledger.record(push.clipId, .ignored, now: now())
            reply(requestId, .ignored(push.clipId, .conflict))
            let conflict = ClipboardConflictData(clipId: push.clipId, originDeviceId: push.originDeviceId,
                                                 deviceId: deviceId, deviceName: deviceName)
            if let peer = phone?.peer { Task { try? await peer.sendConflict(conflict) } }
        case .keepLocal:
            ledger.record(push.clipId, .ignored, now: now())
            reply(requestId, .ignored(push.clipId, .conflict))
        case .write:
            write(content, push: push, requestId: requestId)
        }
    }

    private func write(_ content: ClipContent, push: ClipboardPushData, requestId: String) {
        guard let count = access.write(content, clipId: push.clipId, sensitive: push.sensitive) else {
            ledger.record(push.clipId, .rejected, now: now())
            reply(requestId, .rejected(.internal, clipId: push.clipId))
            return
        }
        let writtenAt = now()
        ownWrite = OwnWrite(changeCount: count, clipId: push.clipId, writtenAt: writtenAt)
        lastSeenChangeCount = count
        received = (content.sha256, writtenAt)
        // The phone's clip won: an older local clip is not replayed over it.
        latestLocal = nil
        BenchLog.event("clip_applied", ["clip": push.clipId])
        ledger.record(push.clipId, .applied, now: writtenAt)
        scheduleAutoClear()
        reply(requestId, .applied(push.clipId))
    }

    /// A change `poll` has not seen yet is a local change right now: poll first so QC8 (a) protects it.
    private func noticeUnseenLocalChange() {
        let count = access.changeCount
        if count != lastSeenChangeCount, count != ownWrite?.changeCount { poll() }
    }

    private func unacknowledgedLocalChange() -> LocalChange? {
        if let clip = latestLocal, !clip.acknowledged {
            return LocalChange(detectedAt: clip.createdAt, originTs: clip.originTs, originDeviceId: deviceId)
        }
        return detectedLocalChange.map {
            LocalChange(detectedAt: $0, originTs: Self.milliseconds($0), originDeviceId: deviceId)
        }
    }

    // MARK: - clipboard/cancel and clipboard/conflict

    private func receiveCancel(_ cancel: ClipboardCancelData) {
        if let transfer = incoming, transfer.transferId == cancel.transferId {
            endIncoming()
            reply(transfer.requestId, .ignored(transfer.push.clipId, .cancelled))
        } else if let current = sending, current.transferId == cancel.transferId {
            current.task.cancel()
            sending = nil
            onProgress(.sending, nil)
            // `user` on the phone: not replayed; `timeout`: treated as not received (CLIP-03 API 5 logic 2).
            if cancel.reason == .user, latestLocal?.clipId == current.clipId { latestLocal?.acknowledged = true }
        }
    }

    /// CLIP-01 API 6 logic 3: "Clipboard Not Updated on <name>" with "Send Again", not for a replayed clip.
    private func receiveConflict(_ conflict: ClipboardConflictData) {
        guard let clip = latestLocal, clip.clipId == conflict.clipId, !clip.replayed else { return }
        heldConflict = HeldClip(content: clip.content, sensitive: clip.sensitive, heldAt: now())
        onAlert(.conflict(deviceName: conflict.deviceName))
    }

    // MARK: - Acks

    /// What the `ack` of a push says (CLIP-01 API 5 response table).
    enum PushResult {
        case applied(String)
        case ignored(String, ClipboardAckData.Reason)
        case rejected(ErrorCode, clipId: String?, transferId: String? = nil)
    }

    func reply(_ requestId: String, _ result: PushResult) {
        guard let phone else { return }
        let ack: Ack
        let status: String
        let clipId: String?
        switch result {
        case .applied(let id):
            ack = .success(re: requestId, data: Self.ackData(ClipboardAckData(clipId: id, status: .applied)))
            (status, clipId) = ("applied", id)
        case .ignored(let id, let reason):
            ack = .success(re: requestId, data: Self.ackData(ClipboardAckData(clipId: id, status: .ignored, reason: reason)))
            (status, clipId) = ("ignored", id)
        case .rejected(let code, let id, let transferId):
            let details = id.map { Self.ackData(ClipboardAckData(clipId: $0, status: .rejected, transferId: transferId)) }
            ack = .failure(re: requestId, error: AckError(code: code, message: Self.diagnostic(code), details: details))
            (status, clipId) = ("rejected", id)
        }
        Task {
            try? await phone.peer.reply(to: requestId, with: ack)
            if let clipId {
                BenchLog.event("ack_sent", ["clip": clipId, "peer": Self.benchId(phone.deviceId), "status": status])
            }
        }
    }

    static func ackData(_ data: ClipboardAckData) -> JSONValue {
        (try? HLJSON.convert(from: data)) ?? .emptyObject
    }

    /// English diagnostics (0.12.4), never content.
    static func diagnostic(_ code: ErrorCode) -> String {
        switch code {
        case .clipTooLarge: "Clip exceeds the size limit"
        case .clipChecksumMismatch: "SHA-256 mismatch"
        case .clipUnsupportedMime: "MIME type not accepted"
        case .featureDisabled: "Clipboard is off"
        case .internal: "Could not write the clipboard"
        default: "Malformed push"
        }
    }
}
