import Foundation
import HLCrypto
import HLProtocol
import HLTransport

extension ClipboardEngine {
    // MARK: - The phone's session

    /// A session reached `Connected` (CONN-01 step 10): the latest local clip the phone has not acknowledged is sent
    /// again when it is less than 120 s old (QC7).
    public func phoneConnected(peer: any ClipboardPeer, deviceId: String, name: String, feature: ClipboardFeature?) {
        phone = Phone(peer: peer, deviceId: deviceId, name: name, feature: feature)
        sessionStartedAt = now()
        guard let clip = latestLocal, !clip.acknowledged,
              now().timeIntervalSince(clip.createdAt) <= ClipboardConstants.staleAfter,
              let phone, accepts(clip.content, phone: phone),
              clip.content.bytes.count <= limit(for: clip.content, phone: phone)
        else { return }
        clip.replayed = true
        deliver(clip, to: phone)
    }

    /// `capability/update` from the phone: a fresh snapshot also lifts a `FEATURE_DISABLED` suspension (E10).
    public func phoneCapabilityUpdated(_ feature: ClipboardFeature?) {
        phone?.feature = feature
        phone?.suspended = false
    }

    /// The session ended: transfers stop and their temporary files are deleted; no resume (CLIP-03 E8).
    public func phoneDisconnected() {
        phone = nil
        sending?.task.cancel()
        sending = nil
        if let incoming {
            incoming.discard()
            self.incoming = nil
        }
        onProgress(.sending, nil)
        onProgress(.receiving, nil)
    }

    /// QC1: clipboard on at both ends, images only when this Mac sends images and the phone takes that MIME type.
    func accepts(_ content: ClipContent, phone: Phone) -> Bool {
        guard settings.clipboardEnabled, !phone.suspended, let feature = phone.feature, feature.enabled else { return false }
        guard case .image(let image) = content else { return true }
        return settings.sendImages && (feature.mimes ?? []).contains(image.mime)
    }

    /// The smaller of this Mac's limit and the phone's (QC1).
    func limit(for content: ClipContent, phone: Phone) -> Int {
        switch content {
        case .text: min(ClipboardConstants.maxTextBytes, Int(phone.feature?.maxTextBytes ?? Int64.max))
        case .image: min(ClipboardConstants.maxImageBytes, Int(phone.feature?.maxImageBytes ?? Int64.max))
        }
    }

    // MARK: - Sending (CLIP-02 API 2, CLIP-03 API 3–4)

    /// A new local clip: it becomes the latest clip (QC7), supersedes a chunked transfer in progress, and goes to the
    /// phone when clipboard is active there.
    func send(_ content: ClipContent, sensitive: Bool, manual: Bool) {
        detectedLocalChange = nil
        let createdAt = now()
        let clip = OutgoingClip(clipId: HLUUID.v7(timestampMs: Self.milliseconds(createdAt)), content: content,
                                sensitive: sensitive, originTs: Self.milliseconds(createdAt), createdAt: createdAt,
                                manual: manual)
        BenchLog.event("clip_read", ["clip": clip.clipId, "kind": content.kind.rawValue,
                                     "bytes": String(content.bytes.count), "source": platform == .ios ? "ios" : "mac"])
        cancelOutgoingTransfer(reason: .superseded)
        latestLocal = clip
        guard let phone else {
            if manual { onNotice(.notConnectedWillSend) }
            return
        }
        guard accepts(content, phone: phone) else { return }
        guard content.bytes.count <= limit(for: content, phone: phone) else {
            onNotice(content.kind == .text ? .textTooLarge : .imageTooLarge)
            return
        }
        deliver(clip, to: phone)
    }

    func deliver(_ clip: OutgoingClip, to phone: Phone) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.transmit(clip, to: phone)
        }
        sending = SendingState(clipId: clip.clipId, transferId: nil, task: task)
    }

    /// One push, resent once with a new `transfer_id` after `CLIP_CHECKSUM_MISMATCH` (CLIP-03 E4). No `ack` in time or
    /// a session that ended leaves the clip unacknowledged for replay (QC7, E9).
    private func transmit(_ clip: OutgoingClip, to phone: Phone) async {
        defer { if sending?.clipId == clip.clipId { sending = nil } }
        var resent = false
        while true {
            guard let ack = try? await push(clip, to: phone) else {
                // The iPhone and iPad say so and never replay: the user pastes again (CLIP-04 E9).
                if platform == .ios, !Task.isCancelled {
                    clip.acknowledged = true
                    onNotice(.sendFailed)
                }
                return
            }
            if !ack.ok, ack.error?.code == .clipChecksumMismatch, !resent {
                resent = true
                continue
            }
            handle(ack, for: clip, from: phone)
            return
        }
    }

    private func push(_ clip: OutgoingClip, to phone: Phone) async throws -> Ack {
        let peerId = Self.benchId(phone.deviceId)
        if let inline = inlinePush(clip) {
            let waiter = try await phone.peer.sendPush(inline)
            BenchLog.event("clip_sent", ["clip": clip.clipId, "peer": peerId])
            return try await waiter.response(timeout: TransportConstants.requestTimeout)
        }
        let bytes = clip.content.bytes
        let chunkSize = ClipboardConstants.chunkSize
        let chunkCount = Int32((bytes.count + chunkSize - 1) / chunkSize)
        let transfer = ClipboardTransfer(transferId: HLUUID.v7(), size: Int64(bytes.count),
                                         sha256: Base64Coding.encodeB64u(clip.content.sha256),
                                         chunkSize: Int32(chunkSize), chunkCount: chunkCount)
        if sending?.clipId == clip.clipId { sending?.transferId = transfer.transferId }
        let waiter = try await phone.peer.sendPush(pushData(clip, transfer: transfer))
        BenchLog.event("clip_sent", ["clip": clip.clipId, "peer": peerId])
        let showsProgress = clip.content.kind == .image && bytes.count > ClipboardConstants.progressThreshold
        defer { if showsProgress { onProgress(.sending, nil) } }
        for index in 0..<Int(transfer.chunkCount) {
            try Task.checkCancellation()
            let start = index * chunkSize
            let chunk = bytes.subdata(in: start..<min(start + chunkSize, bytes.count))
            try await phone.peer.sendChunk(ClipboardChunkPlaintext(transferId: transfer.transferId, index: Int32(index),
                                                                   chunk: chunk))
            if showsProgress {
                onProgress(.sending, ClipboardProgress(direction: .sending, transferId: transfer.transferId,
                                                       deviceName: phone.name,
                                                       fraction: Double(index + 1) / Double(transfer.chunkCount)))
            }
        }
        return try await waiter.response(timeout: TransportConstants.requestTimeout)
    }

    /// The push with the text inline when its plaintext stays within `CLIP_INLINE_MAX` (QC5), else `nil`.
    private func inlinePush(_ clip: OutgoingClip) -> ClipboardPushData? {
        guard case .text = clip.content else { return nil }
        let push = pushData(clip, transfer: nil)
        guard let plaintext = try? TypedPayload(op: ClipboardOp.push.rawValue, data: push).encoded(),
              plaintext.count <= ClipboardConstants.inlineMaxPlaintext
        else { return nil }
        return push
    }

    func pushData(_ clip: OutgoingClip, transfer: ClipboardTransfer?) -> ClipboardPushData {
        var text: String?
        var width: Int32?
        var height: Int32?
        switch clip.content {
        case .text(let value): text = transfer == nil ? value : nil
        case .image(let image):
            width = image.width
            height = image.height
        }
        return ClipboardPushData(clipId: clip.clipId, kind: clip.content.kind, mime: clip.content.mime, text: text,
                                 transfer: transfer, width: width, height: height, sensitive: clip.sensitive,
                                 originTs: clip.originTs, source: platform == .ios ? .ios : .mac,
                                 originDeviceId: deviceId)
    }

    /// CLIP-01 API 5 logic 2–4: `applied`/`ignored` acknowledge the clip; errors are told only for manual sends,
    /// except a failed write on the phone (CLIP-02 E8).
    private func handle(_ ack: Ack, for clip: OutgoingClip, from phone: Phone) {
        let result = ack.ok ? ack.data.flatMap { try? HLJSON.convert($0, to: ClipboardAckData.self) } : nil
        BenchLog.event("ack_received", ["clip": clip.clipId, "peer": Self.benchId(phone.deviceId),
                                        "status": ack.ok ? (result?.status.rawValue ?? "applied") : "rejected"])
        if ack.ok {
            // `ignored`/`cancelled` follows a `clipboard/cancel`, which already decided about replaying.
            if !(result?.status == .ignored && result?.reason == .cancelled) { clip.acknowledged = true }
            if clip.manual, result?.status == .applied { onNotice(.sent(deviceName: phone.name)) }
            return
        }
        clip.acknowledged = true
        switch ack.error?.code {
        case .featureDisabled:
            self.phone?.suspended = true
        case .internal:
            onNotice(.writeFailedOnPhone)
        case .clipChecksumMismatch:
            onNotice(clip.content.kind == .image ? .imageSendFailed : .writeFailedOnPhone)
        case .clipTooLarge where clip.manual:
            onNotice(clip.content.kind == .text ? .textTooLarge : .imageTooLarge)
        default:
            if clip.manual { onNotice(.writeFailedOnPhone) }
        }
    }

    /// Stops the chunked transfer in progress and tells the phone why (CLIP-03 API 5): `superseded` by a newer clip,
    /// or `user` from "Cancel" (then the clip is not replayed).
    func cancelOutgoingTransfer(reason: ClipboardCancelData.Reason) {
        guard let current = sending, let transferId = current.transferId else { return }
        current.task.cancel()
        sending = nil
        onProgress(.sending, nil)
        if reason == .user, latestLocal?.clipId == current.clipId { latestLocal?.acknowledged = true }
        guard let peer = phone?.peer else { return }
        Task { try? await peer.sendCancel(ClipboardCancelData(transferId: transferId, reason: reason)) }
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
