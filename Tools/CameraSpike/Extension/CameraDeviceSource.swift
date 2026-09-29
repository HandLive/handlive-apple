import CameraSpikeKit
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import notify
import os

/// The virtual camera: a source stream read by meeting apps and a sink stream written by the host app, both
/// 1280×720 BGRA at 30 fps. A frame taken from the sink goes out on the source at once with the current host time;
/// when the sink has been silent for more than a second, a placeholder frame goes out at 30 fps instead.
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: CameraStreamSource!
    private var sinkStream: CameraSinkSource!
    private let formatDescription: CMFormatDescription
    private let pool: CVPixelBufferPool
    private let queue = DispatchQueue(label: "app.handlive.spike.camera.frames", qos: .userInteractive)
    private let log = Logger.spike("device")

    // State below is touched on `queue` only.
    private var sourceRunning = false
    private var placeholderTimer: DispatchSourceTimer?
    private var lastSinkFrameNanos: UInt64 = 0
    private var placeholderFrames: Int64 = 0
    private var forwardedFrames: Int64 = 0

    static let frameDuration = CMTime(value: 1, timescale: CMTimeScale(TestPattern.framesPerSecond))

    override init() {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(TestPattern.width), height: Int32(TestPattern.height),
                                       extensions: nil, formatDescriptionOut: &description)
        var newPool: CVPixelBufferPool?
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: TestPattern.width, kCVPixelBufferHeightKey: TestPattern.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &newPool)
        guard let description, let newPool else { fatalError("cannot create the 720p BGRA format or pool") }
        formatDescription = description
        pool = newPool
        super.init()

        device = CMIOExtensionDevice(localizedName: SpikeIdentifiers.cameraName, deviceID: UUID(),
                                     legacyDeviceID: SpikeIdentifiers.cameraUID, source: self)
        let format = CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: Self.frameDuration,
                                               minFrameDuration: Self.frameDuration, validFrameDurations: nil)
        sourceStream = CameraStreamSource(name: "\(SpikeIdentifiers.cameraName) Video", format: format, owner: self)
        sinkStream = CameraSinkSource(name: "\(SpikeIdentifiers.cameraName) Sink", format: format, owner: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("addStream failed: \(error)")
        }
    }

    // MARK: CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "HandLive Camera Spike" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source stream

    func sourceStarted() {
        queue.async { [self] in
            sourceRunning = true
            forwardedFrames = 0
            notify_post(SpikeIdentifiers.demandNotification)
            startPlaceholderTimer()
            log.info("source stream started")
        }
    }

    func sourceStopped() {
        queue.async { [self] in
            sourceRunning = false
            placeholderTimer?.cancel()
            placeholderTimer = nil
            notify_post(SpikeIdentifiers.idleNotification)
            log.info("source stream stopped after \(self.forwardedFrames) forwarded frames")
        }
    }

    // MARK: Sink stream

    /// A frame from the host: send it out on the source stream now, retimed to the current host time.
    func forwardFromSink(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            let now = Self.hostNanos()
            lastSinkFrameNanos = now
            guard sourceRunning, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            send(pixelBuffer, atNanos: now)
            forwardedFrames += 1
        }
    }

    private func startPlaceholderTimer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / TestPattern.framesPerSecond),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.placeholderTick() }
        placeholderTimer = timer
        timer.resume()
    }

    private func placeholderTick() {
        let now = Self.hostNanos()
        guard sourceRunning, now &- lastSinkFrameNanos > 1_000_000_000 else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let canvas = PixelCanvas(base: base, width: CVPixelBufferGetWidth(pixelBuffer),
                                     height: CVPixelBufferGetHeight(pixelBuffer),
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
            TestPattern.renderPlaceholder(on: canvas, frameIndex: placeholderFrames)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        placeholderFrames += 1
        send(pixelBuffer, atNanos: now)
    }

    private func send(_ pixelBuffer: CVPixelBuffer, atNanos nanos: UInt64) {
        var timing = CMSampleTimingInfo(duration: Self.frameDuration,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                        dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                                        formatDescription: formatDescription,
                                                        sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            log.error("CMSampleBufferCreateForImageBuffer failed: \(status)")
            return
        }
        sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: nanos)
    }

    /// Host clock in nanoseconds, the clock of `CMClockGetHostTimeClock()`.
    static func hostNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}
