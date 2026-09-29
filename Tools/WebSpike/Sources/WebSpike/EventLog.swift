import Foundation
import WebSpikeCore

/// Writes `HLWEB` lines with a timestamp to stdout and, with `--log`, to a file. Also keeps the per-install hash salt
/// in `~/Library/Application Support/HandLive Web Spike/salt`.
final class EventLog {
    private let file: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()
    let salt: String

    init(path: String?) {
        if let path {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            file = FileHandle(forWritingAtPath: path)
            file?.seekToEndOfFile()
        } else {
            file = nil
        }
        salt = Self.loadSalt()
    }

    func write(_ fields: KeyValuePairs<String, Any?>) {
        let line = LogLine.format(fields).replacingOccurrences(
            of: LogLine.tag, with: "\(LogLine.tag) ts=\(formatter.string(from: Date()))", options: .anchored
        )
        let data = Data((line + "\n").utf8)
        FileHandle.standardOutput.write(data)
        file?.write(data)
    }

    private static func loadSalt() -> String {
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HandLive Web Spike", isDirectory: true)
        let saltFile = directory.appendingPathComponent("salt")
        if let existing = try? String(contentsOf: saltFile, encoding: .utf8), !existing.isEmpty { return existing }
        let salt = UUID().uuidString
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? salt.write(to: saltFile, atomically: true, encoding: .utf8)
        return salt
    }
}
