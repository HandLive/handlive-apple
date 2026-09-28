/// Latency samples in milliseconds and their summary, printed by the self-checks every few seconds.
public struct LatencyStats: Sendable, Equatable {
    public private(set) var samples: [Double] = []

    public init() {}

    public mutating func add(_ millis: Double) { samples.append(millis) }
    public mutating func reset() { samples.removeAll(keepingCapacity: true) }

    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let min: Double
        public let median: Double
        public let p95: Double
        public let max: Double
    }

    /// `nil` without samples. Percentiles use the nearest-rank method.
    public var summary: Summary? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ percent: Double) -> Double {
            let index = Int((percent / 100 * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
        }
        return Summary(count: sorted.count, min: sorted[0], median: rank(50), p95: rank(95), max: sorted[sorted.count - 1])
    }

    /// Difference `now - stamp` of two 32-bit millisecond counters, correct across one wrap-around.
    public static func elapsedMillis(from stamp: UInt32, to now: UInt32) -> UInt32 { now &- stamp }
}
