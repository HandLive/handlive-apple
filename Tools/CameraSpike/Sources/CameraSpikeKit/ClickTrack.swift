import Foundation

/// The microphone test signal and its detector. The host plays a 20 ms, 1 kHz burst at the start of every host-clock
/// second into the hidden feed device; what comes out of "HandLive Microphone Spike" is scanned for the burst onset,
/// whose offset past the whole second is the loopback latency (valid below one second).
public enum ClickTrack {
    public static let sampleRate = 48_000.0
    public static let burstSeconds = 0.020
    public static let frequency = 1_000.0
    public static let amplitude: Float = 0.5

    /// The signal at host time `seconds`.
    public static func sample(atHostSeconds seconds: Double) -> Float {
        let phase = seconds - seconds.rounded(.down)
        guard phase < burstSeconds else { return 0 }
        return amplitude * Float(sin(2 * Double.pi * frequency * phase))
    }

    /// Finds burst onsets in a stream of input buffers.
    public struct OnsetDetector: Sendable {
        public let threshold: Float
        /// Silence needed before a new onset counts, so one burst is reported once.
        public let rearmSeconds: Double
        private var lastOnset: Double?

        public init(threshold: Float = 0.1, rearmSeconds: Double = 0.5) {
            self.threshold = threshold
            self.rearmSeconds = rearmSeconds
        }

        /// Scans `samples`, the first of which plays at host time `firstSampleSeconds`; returns the host time of each
        /// onset found.
        public mutating func scan(_ samples: UnsafeBufferPointer<Float>, firstSampleSeconds: Double,
                                  sampleRate: Double = ClickTrack.sampleRate) -> [Double] {
            var onsets: [Double] = []
            for (index, value) in samples.enumerated() where abs(value) >= threshold {
                let time = firstSampleSeconds + Double(index) / sampleRate
                if let lastOnset, time - lastOnset < rearmSeconds { continue }
                lastOnset = time
                onsets.append(time)
            }
            return onsets
        }
    }

    /// Latency in milliseconds of an onset heard at host time `onsetSeconds`: its offset past the whole second.
    public static func latencyMillis(ofOnsetAt onsetSeconds: Double) -> Double {
        (onsetSeconds - onsetSeconds.rounded(.down)) * 1000
    }
}
