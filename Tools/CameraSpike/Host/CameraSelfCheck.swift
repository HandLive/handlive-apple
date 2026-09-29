import AVFoundation
import CameraSpikeKit
import CoreVideo
import Foundation

/// Reads the spike camera like a meeting app would (AVFoundation) and measures host → extension → consumer latency
/// from the timestamp strip in each frame. Frames without a valid strip are the extension's placeholder.
final class CameraSelfCheck: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let log: SpikeEventLog
    private let queue = DispatchQueue(label: "app.handlive.spike.camera.selfcheck", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var stats = LatencyStats()
    private var placeholders = 0
    private var lastReport = Date()

    init(log: SpikeEventLog) {
        self.log = log
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            log.record("camera_permission", ["granted": granted])
            guard granted else { return }
            queue.async { self.startSession() }
        }
    }

    func stop() {
        queue.async { [self] in
            session?.stopRunning()
            session = nil
            report()
        }
    }

    private func startSession() {
        guard session == nil else { return }
        VirtualCameraLocator.allowVirtualDevices()
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.external] } else { types = [.externalUnknown] }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: {
            $0.uniqueID == SpikeIdentifiers.cameraUID || $0.localizedName == SpikeIdentifiers.cameraName
        }) else {
            log.record("selfcheck_no_device", ["devices": devices.map { "\($0.localizedName) [\($0.uniqueID)]" }])
            return
        }
        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
        } catch {
            log.record("selfcheck_failed", ["error": "\(error)"])
            return
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.startRunning()
        self.session = session
        stats.reset()
        placeholders = 0
        lastReport = Date()
        log.record("selfcheck_started", ["device": device.localizedName, "unique_id": device.uniqueID,
                                         "format": "\(device.activeFormat.formatDescription.dimensions)"])
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let arrival = SinkFeeder.millis(SinkFeeder.hostNanos())
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let canvas = PixelCanvas(base: base, width: CVPixelBufferGetWidth(pixelBuffer),
                                 height: CVPixelBufferGetHeight(pixelBuffer),
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
        if let stamp = TimestampBarcode.decode(canvas) {
            stats.add(Double(LatencyStats.elapsedMillis(from: stamp, to: arrival)))
        } else {
            placeholders += 1
        }
        if Date().timeIntervalSince(lastReport) >= 5 { report() }
    }

    private func report() {
        let summary = stats.summary
        log.record("selfcheck_latency_ms", ["frames": summary?.count ?? 0, "placeholder_frames": placeholders,
                                            "min": summary?.min ?? -1, "median": summary?.median ?? -1,
                                            "p95": summary?.p95 ?? -1, "max": summary?.max ?? -1,
                                            "fps": Double((summary?.count ?? 0) + placeholders) /
                                                max(Date().timeIntervalSince(lastReport), 0.001)])
        stats.reset()
        placeholders = 0
        lastReport = Date()
    }
}
