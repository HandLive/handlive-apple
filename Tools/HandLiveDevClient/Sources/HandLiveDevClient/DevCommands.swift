import Foundation
import HLAppCore
import HLCalls
import HLProtocol
import HLSMS
import HLTransport

/// The commands that use the session: each starts the link, waits for `Connected`, does its part through the engines,
/// and prints what came back.
@MainActor
struct DevCommands {
    let workspace: DevWorkspace
    let link: DevLink

    static let connectTimeout: Duration = .seconds(30)

    func connect() async -> Bool {
        link.start()
        guard let route = await link.connected(within: Self.connectTimeout) else {
            DevConsole.line("no session with the phone within \(Self.connectTimeout); is the app running and "
                + "`adb forward` in place?")
            return false
        }
        DevConsole.line("session ready (\(route))")
        return true
    }

    func listen(seconds: Int?) async -> Bool {
        guard await connect() else { return false }
        if let seconds {
            try? await Task.sleep(for: .seconds(seconds))
        } else {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
        return true
    }

    /// `answer`, `reject` or `end` through the call controller, for the call the phone reports (an 8-character prefix
    /// of the `call_id`, as `listen` prints it, is enough).
    func callCommand(_ command: CallCommand, callId: String) async -> Bool {
        guard await connect() else { return false }
        let found = await link.log.wait(from: 0, timeout: .seconds(8)) { _ in
            link.calls.call.map { $0.callId.hasPrefix(callId) ? $0.callId : nil } ?? nil
        }
        guard found != nil else {
            DevConsole.line("the phone reports no call \(callId)")
            return false
        }
        let start = link.log.count
        let tapped = ContinuousClock.now
        let outcome = await link.calls.perform(command, from: .menu)
        DevConsole.line("\(command) → \(outcome) after \(Self.elapsed(since: tapped))")
        let next = await link.log.wait(from: start, timeout: .seconds(5)) { event -> CallStateData? in
            if case .callState(let state, _) = event, state.callId.hasPrefix(callId) { return state }
            return nil
        }
        if let next { DevConsole.line("the call is now \(next.value.state.rawValue) (\(Self.elapsed(since: tapped)))") }
        return outcome == .accepted
    }

    /// SMS-04 through the SMS engine: queued in the outbox, sent when the session is up, then the phone's statuses.
    func smsSend(target: String, text: String) async -> Bool {
        guard await connect(), let pairId = workspace.pairedDevice?.pairId else { return false }
        do {
            let localId: String
            if let threadId = Self.threadId(target) {
                guard let thread = try await link.smsStore.thread(pairId: pairId, threadId: threadId) else {
                    DevConsole.line("no conversation \(threadId) on this Mac yet")
                    return false
                }
                localId = try await link.sms.reply(text: text, in: thread, subId: nil)
            } else {
                localId = try await link.sms.send(text: text, toNumber: target, subId: nil)
            }
            DevConsole.line("queued local \(DevLink.short(localId)) to \(DevConsole.number(target))")
            return await followStatus(localId: localId, timeout: .seconds(60)) != nil
        } catch {
            DevConsole.line("sms-send refused: \(error)")
            return false
        }
    }

    /// Waits for the phone's `sms/status` of the message up to `sent`, `delivered` or `failed`; returns the last one.
    func followStatus(localId: String, from start: Int = 0, timeout: Duration) async -> SmsStatusData.Status? {
        var last: SmsStatusData.Status?
        var index = start
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let next = await link.log.wait(from: index, timeout: remaining) { event -> SmsStatusData? in
                if case .smsStatus(let status, _) = event, status.localId == localId { return status }
                return nil
            }
            guard let next else { break }
            index = next.index + 1
            last = next.value.status
            if [.delivered, .failed].contains(next.value.status) { break }
        }
        return last
    }

    /// CLIP-02 "Send Clipboard to Phone" with the text as this Mac's clipboard.
    func clipPush(_ text: String) async -> Bool {
        guard await connect() else { return false }
        let start = link.log.count
        let pushed = ContinuousClock.now
        link.pasteboard.copy(text)
        link.clipboard.sendClipboardNow()
        let notice = await link.log.wait(from: start, timeout: .seconds(15)) { event -> ClipboardNotice? in
            if case .clipboard(let notice) = event { return notice }
            return nil
        }
        guard let notice else {
            DevConsole.line("no answer from the phone")
            return false
        }
        DevConsole.line("clipboard: \(notice.value) after \(Self.elapsed(since: pushed))")
        if case .sent = notice.value { return true }
        return false
    }

    /// CALL-04 `log_sync` after the connection, then the newest entries (numbers masked).
    func logSync() async -> Bool {
        guard await connect(), let pairId = workspace.pairedDevice?.pairId else { return false }
        let status = await link.log.wait(from: 0, timeout: .seconds(30)) { event -> CallLogStatus? in
            if case .callLogStatus(let status) = event, status != .syncing, status != .idle { return status }
            return nil
        }
        DevConsole.line("call log sync: \(status.map { "\($0.value)" } ?? "no answer")")
        let entries = (try? await link.callStore.entries(pairId: pairId, limit: 20)) ?? []
        for entry in entries {
            let when = Date(timeIntervalSince1970: TimeInterval(entry.ts) / 1000).formatted(date: .abbreviated,
                                                                                               time: .standard)
            DevConsole.line("  \(entry.entryId) \(entry.type.rawValue) \(DevConsole.number(entry.number)) \(when) "
                + "\(entry.durationS) s\(entry.isUnseenMissed ? " unseen" : "")")
        }
        return status?.value == .done
    }

    /// A conversation id (`thread:12` or a short number) rather than a phone number.
    static func threadId(_ target: String) -> Int64? {
        if target.hasPrefix("thread:") { return Int64(target.dropFirst("thread:".count)) }
        guard !target.hasPrefix("+"), target.count <= 4 else { return nil }
        return Int64(target)
    }

    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now)
        return "\(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000) ms"
    }
}
