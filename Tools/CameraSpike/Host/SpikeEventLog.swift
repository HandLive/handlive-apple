import Foundation

/// One JSON object per event, shown in the window and appended to
/// `~/Library/Logs/HandLiveCameraSpike/events-<start time>.jsonl`, which the owner attaches to the report.
/// Safe to call from any thread.
final class SpikeEventLog: ObservableObject, @unchecked Sendable {
    @Published private(set) var lines: [String] = []
    let fileURL: URL
    private let queue = DispatchQueue(label: "app.handlive.spike.camera.log")
    private var handle: FileHandle?

    init() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HandLiveCameraSpike", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        fileURL = folder.appendingPathComponent("events-\(stamp).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        record("started", ["macos": ProcessInfo.processInfo.operatingSystemVersionString,
                           "bundle": Bundle.main.bundlePath,
                           "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"])
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["event"] = event
        object["t"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                  formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        // JSONSerialization raises an Objective-C exception on a value it cannot encode: describe those instead.
        if !JSONSerialization.isValidJSONObject(object) { object = object.mapValues { "\($0)" } }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        let line = String(data: data, encoding: .utf8) ?? "{}"
        queue.async { [weak self] in
            self?.handle?.write(Data((line + "\n").utf8))
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lines.append(line)
            if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        }
    }
}
