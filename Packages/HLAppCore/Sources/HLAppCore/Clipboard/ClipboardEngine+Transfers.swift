import Foundation
import HLProtocol

extension ClipboardEngine {
    // MARK: - Incoming chunked clips (CLIP-03 steps 8–11, API 4–5)

    /// Starts receiving the chunks of a push into a temporary file (the caller ended any older transfer).
    func startIncoming(_ push: ClipboardPushData, transfer: ClipboardTransfer, requestId: String) {
        guard let digest = try? Base64Coding.decodeB64u(transfer.sha256),
              let started = try? IncomingTransfer(push: push, transfer: transfer, expectedDigest: digest,
                                                  requestId: requestId, directory: temporaryDirectory)
        else {
            ledger.record(push.clipId, .rejected, now: now())
            reply(requestId, .rejected(.internal, clipId: push.clipId))
            if push.kind == .image { onNotice(.imageNoSpace) }
            return
        }
        incoming = started
        armIdleTimer(started)
        reportIncomingProgress(started, fraction: 0)
    }

    func receiveChunk(_ plaintext: Data) {
        // A chunk of a transfer no longer being received is dropped silently (API 4 logic 2).
        guard let chunk = try? ClipboardChunkPlaintext.parse(plaintext), let transfer = incoming,
              chunk.transferId == transfer.transferId
        else { return }
        armIdleTimer(transfer)
        let push = transfer.push
        let step: IncomingTransfer.Step
        do {
            step = try transfer.append(chunk)
        } catch {
            endIncoming()
            ledger.record(push.clipId, .rejected, now: now())
            reply(transfer.requestId, .rejected(.internal, clipId: push.clipId))
            if push.kind == .image { onNotice(.imageNoSpace) }
            return
        }
        switch step {
        case .progress(let fraction):
            reportIncomingProgress(transfer, fraction: fraction)
        case .outOfOrder:
            endIncoming()
            ledger.record(push.clipId, .rejected, now: now())
            reply(transfer.requestId, .rejected(.badRequest, clipId: push.clipId))
        case .checksumMismatch:
            endIncoming()
            ledger.record(push.clipId, .rejected, now: now())
            reply(transfer.requestId, .rejected(.clipChecksumMismatch, clipId: push.clipId, transferId: transfer.transferId))
        case .complete(let data):
            endIncoming()
            completeIncoming(data, push: push, requestId: transfer.requestId)
        }
    }

    /// Chunked text must be valid UTF-8 once reassembled (API 3 logic 5); an image goes to the clipboard as received.
    private func completeIncoming(_ data: Data, push: ClipboardPushData, requestId: String) {
        switch push.kind {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                ledger.record(push.clipId, .rejected, now: now())
                reply(requestId, .rejected(.badRequest, clipId: push.clipId))
                return
            }
            apply(.text(text), push: push, requestId: requestId)
        case .image:
            let image = ClipImage(data: data, mime: push.mime, width: push.width ?? 0, height: push.height ?? 0)
            apply(.image(image), push: push, requestId: requestId)
        }
    }

    func endIncoming() {
        guard let transfer = incoming else { return }
        transfer.discard()
        incoming = nil
        if showsProgress(transfer) { onProgress(.receiving, nil) }
    }

    /// E7: no chunk for 30 s → `clipboard/cancel timeout`, file deleted, push answered `ignored`/`cancelled`.
    private func armIdleTimer(_ transfer: IncomingTransfer) {
        transfer.idleTimer?.cancel()
        let timeout = transferIdleTimeout
        transfer.idleTimer = Task { [weak self, weak transfer] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let transfer, self.incoming === transfer else { return }
            self.cancelIncoming(transfer, reason: .timeout)
        }
    }

    private func cancelIncoming(_ transfer: IncomingTransfer, reason: ClipboardCancelData.Reason) {
        endIncoming()
        if let peer = phone?.peer {
            let cancel = ClipboardCancelData(transferId: transfer.transferId, reason: reason)
            Task { try? await peer.sendCancel(cancel) }
        }
        reply(transfer.requestId, .ignored(transfer.push.clipId, .cancelled))
    }

    /// "Cancel" on the progress in the menu (E6), on either side: `clipboard/cancel user`.
    public func cancelTransfer(_ transferId: String) {
        if let transfer = incoming, transfer.transferId == transferId {
            cancelIncoming(transfer, reason: .user)
        } else if sending?.transferId == transferId {
            cancelOutgoingTransfer(reason: .user)
        }
    }

    private func showsProgress(_ transfer: IncomingTransfer) -> Bool {
        transfer.push.kind == .image && transfer.transfer.size > Int64(ClipboardConstants.progressThreshold)
    }

    private func reportIncomingProgress(_ transfer: IncomingTransfer, fraction: Double) {
        guard showsProgress(transfer), let phone else { return }
        onProgress(.receiving, ClipboardProgress(direction: .receiving, transferId: transfer.transferId,
                                                 deviceName: phone.name, fraction: fraction))
    }

    // MARK: - Auto-clear (CLIP-05)

    /// Deadline = write time + `clip.auto_clear_s` on the wall clock; a new write or a changed setting reschedules it
    /// (E2, E5); `0` cancels it.
    func scheduleAutoClear() {
        autoClearTask?.cancel()
        autoClearTask = nil
        guard let own = ownWrite, settings.autoClearSeconds > 0 else { return }
        let delay = own.writtenAt.addingTimeInterval(TimeInterval(settings.autoClearSeconds)).timeIntervalSince(now())
        autoClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(0, Int((delay * 1000).rounded(.up)))))
            guard !Task.isCancelled else { return }
            self?.checkAutoClear()
        }
    }

    /// Clears only when `changeCount` still equals HandLive's write (step 7–8), and takes the new `changeCount` as seen
    /// so polling does not treat the clearing as a local copy. Also runs on wake (E6).
    public func checkAutoClear() {
        guard let own = ownWrite, settings.autoClearSeconds > 0 else { return }
        guard now() >= own.writtenAt.addingTimeInterval(TimeInterval(settings.autoClearSeconds)) else {
            scheduleAutoClear()
            return
        }
        if access.changeCount == own.changeCount { lastSeenChangeCount = access.clear() }
        ownWrite = nil
    }

    /// The user changed "Auto-Clear Received Clipboard" (E5).
    public func autoClearSettingChanged() {
        scheduleAutoClear()
    }

    /// E4: a HandLive clip still on the clipboard after a restart gets a full interval again. The iPhone and iPad never
    /// look: their clip carries its own `expirationDate` (CLIP-04 API 1).
    func rearmAutoClearAfterRestart() {
        guard platform == .mac, readingAllowed(), let types = access.firstItemTypes(), types.contains(PasteboardTypeID.clipId)
        else { return }
        ownWrite = OwnWrite(changeCount: access.changeCount,
                            clipId: access.string(forType: PasteboardTypeID.clipId) ?? "", writtenAt: now())
        scheduleAutoClear()
    }
}
