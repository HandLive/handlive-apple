import Foundation
import HLAppCore
import HLCalls
import HLProtocol
import HLSMS
import HLTransport

/// What the dev client saw, in order, with this Mac's receive time: the decoded messages of the phone and the engines'
/// results. The commands and the demo wait on it.
enum DevEvent: Sendable {
    case connected(ConnectionRoute)
    case disconnected
    case callState(CallStateData, envelopeTs: Int64)
    case logNew(CallLogNewData, envelopeTs: Int64)
    case smsNew(SmsNewData, envelopeTs: Int64)
    case smsStatus(SmsStatusData, envelopeTs: Int64)
    case callLogStatus(CallLogStatus)
    case smsSync(SmsSyncStatus)
    case clipboard(ClipboardNotice)
    case missedCall(MissedCall)
}

@MainActor
final class DevEventLog {
    struct Entry {
        let event: DevEvent
        let at: ContinuousClock.Instant
        let wallMs: Int64
    }

    /// A matching event, where it sits in the log, and when it arrived.
    struct Match<T> {
        let value: T
        let index: Int
        let entry: Entry
    }

    private(set) var entries: [Entry] = []

    var count: Int { entries.count }

    func append(_ event: DevEvent) {
        entries.append(Entry(event: event, at: .now, wallMs: Int64(Date().timeIntervalSince1970 * 1000)))
    }

    /// The first event from `start` on that `match` accepts, waiting up to `timeout`.
    func wait<T>(from start: Int, timeout: Duration, _ match: (DevEvent) -> T?) async -> Match<T>? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var index = start
        while true {
            while index < entries.count {
                let entry = entries[index]
                index += 1
                if let value = match(entry.event) { return Match(value: value, index: index - 1, entry: entry) }
            }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
