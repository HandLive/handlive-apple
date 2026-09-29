import SwiftUI

/// The spike's host app: one window with the steps of the runbook as buttons, a large live clock for the
/// screenshot latency method, and the event log. Development-only; its strings are not in the string catalog.
@main
struct CameraSpikeApp: App {
    @StateObject private var log: SpikeEventLog
    private let activator: ExtensionActivator
    private let feeder: SinkFeeder
    private let selfCheck: CameraSelfCheck
    private let mic: MicLoopback

    init() {
        let log = SpikeEventLog()
        _log = StateObject(wrappedValue: log)
        activator = ExtensionActivator(log: log)
        feeder = SinkFeeder(log: log)
        selfCheck = CameraSelfCheck(log: log)
        mic = MicLoopback(log: log)
        DemandObserver.shared.start(log: log)
    }

    var body: some Scene {
        WindowGroup("HandLive Camera Spike") {
            SpikeView(log: log, actions: [
                ("Camera Extension", [
                    ("Activate", activator.activate), ("Properties", activator.inspect),
                    ("Deactivate", activator.deactivate),
                ]),
                ("Camera Feed", [
                    ("Start Feed", feeder.start), ("Stop Feed", feeder.stop),
                    ("Start Self-Check", selfCheck.start), ("Stop Self-Check", selfCheck.stop),
                ]),
                ("Microphone", [
                    ("Check Devices", mic.inspectDevices), ("Start Clicks", mic.startFeed),
                    ("Stop Clicks", mic.stopFeed), ("Start Listening", mic.startListening),
                    ("Stop Listening", mic.stopListening),
                ]),
            ])
        }
    }
}

struct SpikeView: View {
    @ObservedObject var log: SpikeEventLog
    let actions: [(String, [(String, () -> Void)])]

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.animation) { context in
                Text(Self.clockFormatter.string(from: context.date))
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
            }
            ForEach(actions, id: \.0) { group in
                HStack {
                    Text(group.0).frame(width: 140, alignment: .leading)
                    ForEach(group.1, id: \.0) { action in
                        Button(action.0, action: action.1)
                    }
                }
            }
            Text("Log: \(log.fileURL.path)").font(.caption).textSelection(.enabled)
            ScrollViewReader { proxy in
                List(Array(log.lines.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(item.offset)
                }
                .onChange(of: log.lines.count) { count in proxy.scrollTo(count - 1) }
            }
        }
        .padding()
        .frame(minWidth: 820, minHeight: 600)
    }
}
