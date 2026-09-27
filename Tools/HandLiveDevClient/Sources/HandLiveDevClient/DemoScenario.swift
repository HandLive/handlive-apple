import Foundation
import HLAppCore
import HLCalls
import HLProtocol
import HLSMS
import HLTransport

/// Test numbers of the emulator's modem, never real ones.
enum DemoNumber {
    static let ring = "5550101"
    static let decline = "5550102"
    static let missed = "5550103"
    static let smsIn = "5550104"
    static let smsOut = "5550105"
}

/// `demo`: calls and SMS made on the emulator's modem (`adb emu gsm …`, `adb emu sms send`) and handled by the real
/// Mac code, each step checked on both sides and timed. The session stays up through the whole scenario.
@MainActor
struct DemoScenario {
    struct Step {
        let name: String
        let passed: Bool
        let detail: String
    }

    let commands: DevCommands
    let phone: PhoneDriver
    var link: DevLink { commands.link }

    func run() async -> [Step] {
        guard await commands.connect() else { return [Step(name: "session", passed: false, detail: "no session")] }
        await settle()
        var steps: [Step] = []
        steps += await answerAndEnd()
        steps.append(await declineSecondCall())
        steps.append(await missedCall())
        steps.append(await incomingSms())
        steps.append(await smsFromMac())
        steps.append(await reconnect())
        let failed = steps.filter { !$0.passed }.count
        DevConsole.line("demo: \(steps.count - failed) of \(steps.count) steps passed")
        return steps
    }

    /// Lets the first `log_sync` and SMS sync finish, so their pages are not taken for the scenario's events.
    private func settle() async {
        _ = await link.log.wait(from: 0, timeout: .seconds(20)) { event -> Bool? in
            if case .callLogStatus(let status) = event, status != .syncing, status != .idle { return true }
            return nil
        }
        _ = await link.log.wait(from: 0, timeout: .seconds(20)) { event -> Bool? in
            if case .smsSync(.done) = event { return true }
            return nil
        }
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: - Helpers shared by the steps

    func record(_ passed: Bool, _ name: String, _ detail: String) -> Step {
        DevConsole.result(passed, name, detail)
        return Step(name: name, passed: passed, detail: detail)
    }

    /// The next `call_event/state` from `start` on that `match` accepts.
    func nextState(from start: Int, timeout: Duration = .seconds(15),
                   _ match: @escaping (CallStateData) -> Bool) async -> DevEventLog.Match<CallStateData>? {
        await link.log.wait(from: start, timeout: timeout) { event -> CallStateData? in
            if case .callState(let state, _) = event, match(state) { return state }
            return nil
        }
    }

    /// `gsm list` of the emulator's modem: one line per call, e.g. `inbound from 5550101 : active`.
    func modemCalls() async -> [String] {
        let output = (try? await phone.console("gsm list")) ?? ""
        return output.split(whereSeparator: \.isNewline).map { String($0) }.filter { $0.contains("from") }
    }

    /// "412 ms after the command, 120 ms after the phone sent it".
    func timing(_ match: DevEventLog.Entry, since start: ContinuousClock.Instant, envelopeTs: Int64) -> String {
        let fromCommand = start.duration(to: match.at)
        let milliseconds = fromCommand.components.seconds * 1000
            + fromCommand.components.attoseconds / 1_000_000_000_000_000
        return "\(milliseconds) ms after the command, \(match.wallMs - envelopeTs) ms after the phone sent it"
    }
}
