import Foundation
import HLProtocol
import HLSMS
import HLTransport

extension DemoScenario {
    /// An SMS arriving on the emulator's modem → the phone's `sms/new` → stored by the Mac's SMS engine.
    func incomingSms() async -> Step {
        let name = "an incoming SMS → sms/new"
        let text = "HandLive demo \(Int.random(in: 1000...9999))"
        let start = link.log.count
        let sent = ContinuousClock.now
        guard (try? await phone.console("sms send \(DemoNumber.smsIn) \(text)")) != nil else {
            return record(false, name, "the emulator refused `sms send`")
        }
        let new = await link.log.wait(from: start, timeout: .seconds(20)) { event -> SmsNewData? in
            if case .smsNew(let new, _) = event, new.message.box == .inbox, new.message.body == text { return new }
            return nil
        }
        guard let new else { return record(false, name, "no sms/new with the text") }
        return record(true, name, "thread \(new.value.message.threadId), "
            + timing(new.entry, since: sent, envelopeTs: envelopeTs(new.entry)))
    }

    /// SMS-04 from the Mac: the outbox, `sms/send`, the phone's radio, and `sms/status` moving forward.
    func smsFromMac() async -> Step {
        let name = "an SMS from the Mac → the phone sends it"
        let text = "Reply from the Mac \(Int.random(in: 1000...9999))"
        let start = link.log.count
        let queued = ContinuousClock.now
        guard let localId = try? await link.sms.send(text: text, toNumber: DemoNumber.smsOut, subId: nil) else {
            return record(false, name, "the SMS engine refused the message")
        }
        let sent = await link.log.wait(from: start, timeout: .seconds(30)) { event -> SmsStatusData? in
            if case .smsStatus(let status, _) = event, status.localId == localId,
               [.sent, .delivered, .failed].contains(status.status) { return status }
            return nil
        }
        if sent?.value.status == .sent {
            _ = await link.log.wait(from: sent.map { $0.index + 1 } ?? start, timeout: .seconds(5)) { event -> Bool? in
                if case .smsStatus(let status, _) = event, status.localId == localId, status.status == .delivered {
                    return true
                }
                return nil
            }
        }
        let statuses = link.log.entries[start...].compactMap { entry -> String? in
            if case .smsStatus(let status, _) = entry.event, status.localId == localId { return status.status.rawValue }
            return nil
        }
        let outbox = (try? await link.smsStore.outboxEntry(localId: localId))?.state.rawValue ?? "none"
        let passed = sent.map { [.sent, .delivered].contains($0.value.status) } ?? false
        let timingText = sent.map { "sent \(timing($0.entry, since: queued, envelopeTs: envelopeTs($0.entry)))" }
        return record(passed, name, "statuses \(statuses.joined(separator: " → ")); outbox \(outbox)"
            + (timingText.map { "; \($0)" } ?? ""))
    }

    /// CONN-02 E2: the Mac sleeps (`session/bye`, the connection closes) and wakes; the manager connects again.
    func reconnect() async -> Step {
        let name = "the Mac sleeps and wakes → the session comes back"
        let drops = link.log.entries.filter { if case .disconnected = $0.event { return true } else { return false } }
        let start = link.log.count
        await link.manager.systemWillSleep()
        _ = await link.log.wait(from: start, timeout: .seconds(10)) { event -> Bool? in
            if case .disconnected = event { return true }
            return nil
        }
        try? await Task.sleep(for: .seconds(2))
        let woke = ContinuousClock.now
        let afterSleep = link.log.count
        await link.manager.systemDidWake()
        let back = await link.log.wait(from: afterSleep, timeout: .seconds(30)) { event -> ConnectionRoute? in
            if case .connected(let route) = event { return route }
            return nil
        }
        guard let back else { return record(false, name, "no session within 30 s of waking") }
        let elapsed = woke.duration(to: back.entry.at)
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        return record(true, name, "connected again (\(back.value)) \(milliseconds) ms after waking; "
            + "\(drops.count) drop(s) before, while the scenario ran")
    }
}
