import Foundation

/// One JSON object per line on stdout and, with `--log`, in a file: what the probe saw and when (the wall clock and
/// milliseconds since the start). Phone numbers and caller names are never written.
final class EventLog {
    private let start = DispatchTime.now()
    private let file: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    init(path: String?) {
        guard let path else {
            file = nil
            return
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        file = FileHandle(forWritingAtPath: path)
    }

    /// Milliseconds since the probe started, from the monotonic clock.
    var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    func event(_ name: String, _ fields: [String: Any] = [:]) {
        var record: [String: Any] = ["ev": name, "t_ms": (elapsedMs * 10).rounded() / 10,
                                     "wall": formatter.string(from: Date())]
        record.merge(fields) { current, _ in current }
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        let line = data + Data("\n".utf8)
        FileHandle.standardOutput.write(line)
        file?.write(line)
    }
}
