/// Frame timing of the generated test pattern: which frame is due at a given host time, and how many frames a late
/// timer skipped. Times are host-clock nanoseconds (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`), the clock that
/// CoreMediaIO stamps frames with.
public struct FrameClock: Sendable, Equatable {
    public let framesPerSecond: Int
    public let startNanos: UInt64

    public init(framesPerSecond: Int, startNanos: UInt64) {
        precondition(framesPerSecond > 0, "framesPerSecond must be positive")
        self.framesPerSecond = framesPerSecond
        self.startNanos = startNanos
    }

    /// Duration of one frame in nanoseconds (33,333,333 at 30 fps).
    public var frameNanos: UInt64 { 1_000_000_000 / UInt64(framesPerSecond) }

    /// Index of the frame whose slot contains `nanos`; 0 before the start.
    public func frameIndex(atNanos nanos: UInt64) -> Int64 {
        guard nanos > startNanos else { return 0 }
        return Int64((nanos - startNanos) * UInt64(framesPerSecond) / 1_000_000_000)
    }

    /// Presentation time of `frame`, the start of its slot (rounded up, so that it falls inside the slot).
    public func presentationNanos(ofFrame frame: Int64) -> UInt64 {
        let fps = UInt64(framesPerSecond)
        return startNanos + (UInt64(max(frame, 0)) * 1_000_000_000 + fps - 1) / fps
    }

    /// The frame to send when a timer fires at `nanos` after `lastSent` was sent, and how many frames in between were
    /// skipped because the timer ran late. `nil` when the current slot was already sent (the timer ran early).
    public func nextFrame(after lastSent: Int64?, atNanos nanos: UInt64) -> (frame: Int64, skipped: Int64)? {
        let due = frameIndex(atNanos: nanos)
        guard let lastSent else { return (due, 0) }
        guard due > lastSent else { return nil }
        return (due, due - lastSent - 1)
    }
}
