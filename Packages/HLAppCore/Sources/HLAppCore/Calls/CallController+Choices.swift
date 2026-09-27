import Foundation

extension CallController {
    /// "Ignore" (CALL-01 field 9): no panel and no ringing here; the phone keeps ringing and the call stays in the
    /// menu bar menu.
    public func ignore() {
        guard var current = call, current.phase == .ringing || current.phase == .waiting else { return }
        current.ignored = true
        call = current
    }

    /// The call's notification was clicked: the panel comes back (CALL-01 API 7 "Response").
    public func showAgain() {
        guard var current = call, current.ignored else { return }
        current.ignored = false
        call = current
    }

    /// The problem line was read or the panel changed: it goes away.
    public func clearProblem() {
        guard var current = call, current.problem != nil else { return }
        current.problem = nil
        call = current
    }
}
