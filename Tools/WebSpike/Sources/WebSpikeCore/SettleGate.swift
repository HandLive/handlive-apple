/// `WEB_SETTLE` in seconds (W3, W4).
public let webSettleSeconds = 1.5

/// Debounce for `WEB_SETTLE` (W4, same rule as Android): a page is reported once its address has stayed the same
/// for `settle` seconds, and only once until it changes. Used from the main thread only.
public struct SettleGate<Value: Equatable> {
    private let settle: Double
    private var candidate: Value?
    private var since: Double = 0
    private var reported: Value?

    public init(settle: Double = webSettleSeconds) {
        self.settle = settle
    }

    /// Records the value seen at `now` (nil: none). Returns the value to report now, if it is due.
    public mutating func observe(_ value: Value?, now: Double) -> Value? {
        guard let value else {
            candidate = nil
            return nil
        }
        if value != candidate {
            candidate = value
            since = now
        }
        guard value != reported, now - since >= settle else { return nil }
        reported = value
        return value
    }

    /// The reported page ended (browser deactivated, screen locked, private): the same page counts as new again.
    public mutating func reset() {
        candidate = nil
        reported = nil
    }
}
