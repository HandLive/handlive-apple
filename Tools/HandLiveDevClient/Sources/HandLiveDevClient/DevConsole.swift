import Foundation

/// Console output of the dev client: one timestamped line per event. Phone numbers keep only their last two digits
/// and names only their first letter; message texts are never printed, only their length.
enum DevConsole {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func line(_ text: String) {
        print("\(clock.string(from: Date()))  \(text)")
        fflush(stdout)
    }

    /// A step of a scenario: `PASS`/`FAIL` with what was measured.
    static func result(_ passed: Bool, _ step: String, _ detail: String) {
        line("\(passed ? "PASS" : "FAIL")  \(step) — \(detail)")
    }

    /// "+84900000123" → "+•••••••••23"; `nil` → "none".
    static func number(_ number: String?) -> String {
        guard let number, !number.isEmpty else { return "none" }
        let digits = number.filter(\.isNumber).count
        var seen = 0
        return String(number.map { character -> Character in
            guard character.isNumber else { return character }
            seen += 1
            return seen > digits - 2 ? character : "•"
        })
    }

    /// "Nguyễn Văn A" → "N•••"; `nil` → "none".
    static func name(_ name: String?) -> String {
        guard let first = name?.first else { return "none" }
        return "\(first)•••"
    }

    /// Milliseconds between the phone's envelope `ts` and now on this Mac (the emulator follows the host clock).
    static func latency(since ts: Int64, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        "\(now - ts) ms after the phone sent it"
    }
}
