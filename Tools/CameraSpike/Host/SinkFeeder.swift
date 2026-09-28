import CameraSpikeKit
import CoreMediaIO
import CoreVideo
import Foundation

/// Pushes the 720p30 test pattern into the spike camera's sink stream (CAM-02 API 11): the sink queue from
/// `CMIOStreamCopyBufferQueue`, `CMIODeviceStartStream`, then one `CMSimpleQueueEnqueue` per frame slot.
final class SinkFeeder {
    private let log: SpikeEventLog
    private let queue = DispatchQueue(label: "app.handlive.spike.camera.feeder", qos: .userInteractive)
    private var camera: VirtualCameraLocator.Found?
    private var sinkQueue: CMSimpleQueue?
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMFormatDescription?
    private var clock = FrameClock(framesPerSecond: TestPattern.framesPerSecond, startNanos: 0)
    private var lastFrame: Int64?
    private var counters = (sent: 0, queueFull: 0, skipped: Int64(0))
    private var lastReportNanos: UInt64 = 0
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(log: SpikeEventLog) {
        self.log = log
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            do {
                try open()
            } catch {
                log.record("feeder_failed", ["error": "\(error)"])
                close()
                return
            }
            clock = FrameClock(framesPerSecond: TestPattern.framesPerSecond, startNanos: Self.hostNanos())
            lastFrame = nil
            counters = (0, 0, 0)
            lastReportNanos = clock.startNanos
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            // Twice the frame rate: a late tick still lands in the right slot; `nextFrame` sends each slot once.
            timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(clock.frameNanos / 2)), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
            log.record("feeder_started", ["width": TestPattern.width, "height": TestPattern.height,
                                          "fps": TestPattern.framesPerSecond])
        }
    }

    func stop() {
        queue.async { [self] in
            guard timer != nil else { return }
            report(final: true)
            close()
        }
    }

    private func open() throws {
        let camera = try VirtualCameraLocator.locate()
        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        var status = CMIOStreamCopyBufferQueue(camera.sinkStreamID, { _, _, _ in }, nil, &unmanagedQueue)
        guard status == noErr, let unmanagedQueue else {
            throw VirtualCameraLocator.Failure.status("CMIOStreamCopyBufferQueue", status)
        }
        sinkQueue = unmanagedQueue.takeRetainedValue()
        status = CMIODeviceStartStream(camera.deviceID, camera.sinkStreamID)
        guard status == noErr else { throw VirtualCameraLocator.Failure.status("CMIODeviceStartStream", status) }
        self.camera = camera

        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: TestPattern.width, kCVPixelBufferHeightKey: TestPattern.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(TestPattern.width), height: Int32(TestPattern.height),
                                       extensions: nil, formatDescriptionOut: &formatDescription)
        log.record("sink_opened", ["device_id": camera.deviceID, "sink_stream_id": camera.sinkStreamID,
                                   "source_stream_id": camera.sourceStreamID.map { Int($0) } ?? -1,
                                   "queue_capacity": CMSimpleQueueGetCapacity(sinkQueue!)])
    }

    private func close() {
        timer?.cancel()
        timer = nil
        if let camera { CMIODeviceStopStream(camera.deviceID, camera.sinkStreamID) }
        camera = nil
        sinkQueue = nil
    }

    private func tick() {
        let now = Self.hostNanos()
        guard let (frame, skipped) = clock.nextFrame(after: lastFrame, atNanos: now) else { return }
        lastFrame = frame
        counters.skipped += skipped
        if let sampleBuffer = makeFrame(frame, nanos: now), let sinkQueue {
            if CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) {
                CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
                counters.sent += 1
            } else {
                counters.queueFull += 1
            }
        }
        if now - lastReportNanos >= 5_000_000_000 { report(final: false) }
    }

    private func makeFrame(_ frame: Int64, nanos: UInt64) -> CMSampleBuffer? {
        guard let pool, let formatDescription else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let canvas = PixelCanvas(base: base, width: CVPixelBufferGetWidth(pixelBuffer),
                                     height: CVPixelBufferGetHeight(pixelBuffer),
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
            TestPattern.render(on: canvas, frameIndex: frame, stampMillis: Self.millis(nanos),
                               clockText: clockFormatter.string(from: Date()))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(TestPattern.framesPerSecond)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                                           sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    private func report(final: Bool) {
        let now = Self.hostNanos()
        let seconds = Double(now - clock.startNanos) / 1e9
        log.record(final ? "feeder_stopped" : "feeder_stats",
                   ["seconds": (seconds * 10).rounded() / 10, "sent": counters.sent, "queue_full": counters.queueFull,
                    "timer_skipped": counters.skipped,
                    "fps": seconds > 0 ? (Double(counters.sent) / seconds * 10).rounded() / 10 : 0])
        lastReportNanos = now
    }

    static func hostNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static func millis(_ nanos: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: nanos / 1_000_000) }
}
