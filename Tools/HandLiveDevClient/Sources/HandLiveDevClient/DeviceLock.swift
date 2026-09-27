import Foundation

/// A lock directory shared by everyone who drives the same emulator (`mkdir` is atomic): taken before UI taps,
/// pairing and `adb emu` commands, released after the scenario. A lock older than 30 minutes is stale.
final class DeviceLock: @unchecked Sendable {
    struct Busy: Error, CustomStringConvertible {
        let description: String
    }

    static let staleAfter: TimeInterval = 30 * 60
    private let directory: URL
    private let lock = NSLock()
    private var held = false

    init(directory: URL) {
        self.directory = directory
    }

    /// Takes the lock for `purpose`, retrying every 30 s for at most `wait` (a stale lock goes after 30 minutes).
    func acquire(_ purpose: String, wait: Duration = .seconds(35 * 60)) async throws {
        let deadline = ContinuousClock.now.advanced(by: wait)
        while true {
            if try takeOnce(purpose) { return }
            let owner = (try? String(contentsOf: directory.appendingPathComponent("owner"), encoding: .utf8)) ?? "?"
            guard ContinuousClock.now < deadline else {
                throw Busy(description: "the emulator lock is held: \(owner.trimmingCharacters(in: .newlines))")
            }
            DevConsole.line("waiting for the emulator lock (\(owner.trimmingCharacters(in: .newlines)))")
            try await Task.sleep(for: .seconds(30))
        }
    }

    private func takeOnce(_ purpose: String) throws -> Bool {
        removeIfStale()
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return false
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try "apple-client \(stamp) \(purpose)\n".write(to: directory.appendingPathComponent("owner"), atomically: true,
                                                        encoding: .utf8)
        lock.withLock { held = true }
        return true
    }

    private func removeIfStale() {
        guard let created = try? FileManager.default.attributesOfItem(atPath: directory.path)[.creationDate] as? Date,
              Date().timeIntervalSince(created) > Self.staleAfter else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Releases the lock if this process holds it; safe to call more than once.
    func release() {
        let wasHeld = lock.withLock {
            defer { held = false }
            return held
        }
        if wasHeld { try? FileManager.default.removeItem(at: directory) }
    }
}
