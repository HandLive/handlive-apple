import Testing
@testable import CameraSpikeKit

@Suite struct FrameClockTests {
    let clock = FrameClock(framesPerSecond: 30, startNanos: 5_000_000_000)

    @Test func frameIndexFollowsTheHostClock() {
        #expect(clock.frameIndex(atNanos: 0) == 0)
        #expect(clock.frameIndex(atNanos: 5_000_000_000) == 0)
        #expect(clock.frameIndex(atNanos: 5_033_333_332) == 0)
        #expect(clock.frameIndex(atNanos: 5_033_333_334) == 1)
        #expect(clock.frameIndex(atNanos: 6_000_000_000) == 30)
        #expect(clock.frameIndex(atNanos: 5_000_000_000 + 3_600_000_000_000) == 108_000)
    }

    @Test func presentationTimeIsTheStartOfTheSlot() {
        #expect(clock.presentationNanos(ofFrame: 0) == 5_000_000_000)
        #expect(clock.presentationNanos(ofFrame: 30) == 6_000_000_000)
        #expect(clock.frameIndex(atNanos: clock.presentationNanos(ofFrame: 1234)) == 1234)
        #expect(clock.frameNanos == 33_333_333)
    }

    @Test func lateTimerSkipsFramesAndEarlyTimerSendsNothing() {
        #expect(clock.nextFrame(after: nil, atNanos: 5_100_000_000)! == (3, 0))
        #expect(clock.nextFrame(after: 3, atNanos: 5_110_000_000) == nil)
        #expect(clock.nextFrame(after: 3, atNanos: 5_140_000_000)! == (4, 0))
        #expect(clock.nextFrame(after: 4, atNanos: 5_250_000_000)! == (7, 2))
    }
}

@Suite struct LatencyStatsTests {
    @Test func summaryUsesNearestRank() throws {
        var stats = LatencyStats()
        #expect(stats.summary == nil)
        for value in 1...100 { stats.add(Double(value)) }
        let summary = try #require(stats.summary)
        #expect(summary == .init(count: 100, min: 1, median: 50, p95: 95, max: 100))
        stats.reset()
        stats.add(42)
        #expect(stats.summary == .init(count: 1, min: 42, median: 42, p95: 42, max: 42))
    }

    @Test func elapsedMillisWrapsAround() {
        #expect(LatencyStats.elapsedMillis(from: 1000, to: 1045) == 45)
        #expect(LatencyStats.elapsedMillis(from: UInt32.max - 9, to: 20) == 30)
    }
}

@Suite struct ClickTrackTests {
    @Test func burstPlaysOnlyAtTheStartOfEachSecond() {
        #expect(ClickTrack.sample(atHostSeconds: 100.0) == 0)
        #expect(abs(ClickTrack.sample(atHostSeconds: 100.00025) - 0.5) < 0.001)
        #expect(ClickTrack.sample(atHostSeconds: 100.021) == 0)
        #expect(ClickTrack.sample(atHostSeconds: 100.5) == 0)
    }

    @Test func detectorReportsEachBurstOnceWithItsLatency() {
        // 3 s of the click track as heard 12.5 ms late, in 10 ms buffers.
        var detector = ClickTrack.OnsetDetector()
        var onsets: [Double] = []
        let start = 50.0, frames = 480
        for buffer in 0..<300 {
            let first = start + Double(buffer * frames) / ClickTrack.sampleRate
            let samples = (0..<frames).map {
                ClickTrack.sample(atHostSeconds: first + Double($0) / ClickTrack.sampleRate - 0.0125)
            }
            onsets += samples.withUnsafeBufferPointer { detector.scan($0, firstSampleSeconds: first) }
        }
        #expect(onsets.count == 3)
        for onset in onsets {
            #expect(abs(ClickTrack.latencyMillis(ofOnsetAt: onset) - 12.5) < 0.2)
        }
    }
}
