import CoreMediaIO
import Foundation
import os

/// The source stream that meeting apps read. Every client may start it.
final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: CameraDeviceSource

    init(name: String, format: CMIOExtensionStreamFormat, owner: CameraDeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: UUID(), direction: .source, clockType: .hostTime,
                                     source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CameraDeviceSource.frameDuration }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        Logger.spike("source").info("start by pid=\(client.pid) signingID=\(client.signingID ?? "-", privacy: .public)")
        return true
    }

    func startStream() throws { owner.sourceStarted() }

    func stopStream() throws { owner.sourceStopped() }
}

/// The sink stream the host app writes into. Only a client whose signing ID is the host's may start it
/// (CAM-01 API 3 rule 3); the spike logs the signing ID it saw so the owner can check the rule works when signed.
final class CameraSinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: CameraDeviceSource
    private let log = Logger.spike("sink")
    private let lock = NSLock()
    private var client: CMIOExtensionClient?
    private var running = false
    private var consumed: UInt64 = 0

    init(name: String, format: CMIOExtensionStreamFormat, owner: CameraDeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: UUID(), direction: .sink, clockType: .hostTime,
                                     source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CameraDeviceSource.frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(.streamSinkBufferUnderrunCount) { result.sinkBufferUnderrunCount = 0 }
        if properties.contains(.streamSinkEndOfData) { result.sinkEndOfData = 0 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        let allowed = client.signingID == SpikeIdentifiers.hostBundleID
        log.info("""
            sink start requested by pid=\(client.pid) signingID=\(client.signingID ?? "-", privacy: .public) \
            allowed=\(allowed)
            """)
        if allowed {
            lock.withLock { self.client = client }
        }
        return allowed
    }

    func startStream() throws {
        let client: CMIOExtensionClient? = lock.withLock {
            running = true
            return self.client
        }
        guard let client else { return }
        log.info("sink stream started")
        consume(from: client)
    }

    func stopStream() throws {
        let total: UInt64 = lock.withLock {
            running = false
            client = nil
            return consumed
        }
        log.info("sink stream stopped after \(total) frames")
    }

    /// Takes the next frame the host enqueued; asks again right away after a frame, after 2 ms when none was ready.
    private func consume(from client: CMIOExtensionClient) {
        guard lock.withLock({ running }) else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequence, _, _, error in
            guard let self else { return }
            if let sampleBuffer {
                self.owner.forwardFromSink(sampleBuffer)
                self.lock.withLock { self.consumed += 1 }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequence,
                                                          hostTimeInNanoseconds: CameraDeviceSource.hostNanos())
                self.stream.notifyScheduledOutputChanged(output)
                self.consume(from: client)
            } else {
                if let error { self.log.debug("consume: \(String(describing: error), privacy: .public)") }
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(2)) {
                    self.consume(from: client)
                }
            }
        }
    }
}
