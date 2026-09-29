import AudioToolbox
import CameraSpikeKit
import CoreAudio
import Foundation

/// Plays the click track into the hidden feed device (what M-APP does in CAM-02 API 12), and optionally listens to
/// "HandLive Microphone Spike" to confirm the loopback and measure its latency from the burst onsets.
final class MicLoopback {
    private let log: SpikeEventLog
    private var feedUnit: AudioUnit?
    private var listenUnit: AudioUnit?
    private var listener: Listener?

    init(log: SpikeEventLog) {
        self.log = log
    }

    /// Reports whether the driver's two devices exist and how they look (CAM-01 API 4).
    func inspectDevices() {
        var fields: [String: Any] = [:]
        for (key, uid) in [("feed", SpikeIdentifiers.micFeedUID), ("input", SpikeIdentifiers.micInputUID)] {
            if let device = AudioUnitIO.device(withUID: uid) {
                fields[key] = ["id": device,
                               "hidden": AudioUnitIO.uint32(kAudioDevicePropertyIsHidden, of: device) ?? 99,
                               "running_somewhere": AudioUnitIO.uint32(kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                                       of: device) ?? 99]
            } else {
                fields[key] = "missing"
            }
        }
        log.record("mic_devices", fields)
    }

    func startFeed() {
        guard feedUnit == nil else { return }
        do {
            guard let device = AudioUnitIO.device(withUID: SpikeIdentifiers.micFeedUID) else {
                throw AudioUnitIO.Failure(call: "lookup \(SpikeIdentifiers.micFeedUID)", status: -1)
            }
            let unit = try AudioUnitIO.makeHALUnit(device: device, input: false)
            let callback = AURenderCallbackStruct(inputProc: MicLoopback.renderClickTrack, inputProcRefCon: nil)
            try AudioUnitIO.set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, callback)
            try AudioUnitIO.check("AudioUnitInitialize", AudioUnitInitialize(unit))
            try AudioUnitIO.check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
            feedUnit = unit
            log.record("mic_feed_started", ["device": device])
        } catch {
            log.record("mic_feed_failed", ["error": "\(error)"])
        }
    }

    func stopFeed() {
        guard let unit = feedUnit else { return }
        AudioOutputUnitStop(unit)
        AudioComponentInstanceDispose(unit)
        feedUnit = nil
        log.record("mic_feed_stopped")
    }

    func startListening() {
        guard listenUnit == nil else { return }
        do {
            guard let device = AudioUnitIO.device(withUID: SpikeIdentifiers.micInputUID) else {
                throw AudioUnitIO.Failure(call: "lookup \(SpikeIdentifiers.micInputUID)", status: -1)
            }
            let unit = try AudioUnitIO.makeHALUnit(device: device, input: true)
            let listener = Listener(unit: unit, log: log)
            let callback = AURenderCallbackStruct(inputProc: MicLoopback.captureInput,
                                                  inputProcRefCon: Unmanaged.passUnretained(listener).toOpaque())
            try AudioUnitIO.set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback)
            try AudioUnitIO.check("AudioUnitInitialize", AudioUnitInitialize(unit))
            try AudioUnitIO.check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
            self.listener = listener
            listenUnit = unit
            log.record("mic_listen_started", ["device": device])
        } catch {
            log.record("mic_listen_failed", ["error": "\(error)"])
        }
    }

    func stopListening() {
        guard let unit = listenUnit else { return }
        AudioOutputUnitStop(unit)
        AudioComponentInstanceDispose(unit)
        listener?.report()
        listenUnit = nil
        listener = nil
        log.record("mic_listen_stopped")
    }

    /// Render callback of the feed unit: the click track at the host time each sample reaches the device.
    private static let renderClickTrack: AURenderCallback = { _, _, timeStamp, _, frames, buffers in
        guard let buffers, let data = UnsafeMutableAudioBufferListPointer(buffers).first?.mData else { return noErr }
        let samples = data.assumingMemoryBound(to: Float.self)
        let start = timeStamp.pointee.mFlags.contains(.hostTimeValid)
            ? AudioUnitIO.seconds(ofHostTime: timeStamp.pointee.mHostTime) : 0
        for index in 0..<Int(frames) {
            samples[index] = ClickTrack.sample(atHostSeconds: start + Double(index) / AudioUnitIO.sampleRate)
        }
        return noErr
    }

    /// Input callback of the listening unit: pull the samples, then look for burst onsets.
    private static let captureInput: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
        let listener = Unmanaged<Listener>.fromOpaque(refCon).takeUnretainedValue()
        return listener.capture(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
    }

    /// State of the listening unit, reached from its real-time callback.
    final class Listener {
        let unit: AudioUnit
        private let log: SpikeEventLog
        private var buffer = [Float](repeating: 0, count: 8192)
        private var detector = ClickTrack.OnsetDetector()
        private var stats = LatencyStats()
        private var peak: Float = 0
        private let reportQueue = DispatchQueue(label: "app.handlive.spike.mic.report")

        init(unit: AudioUnit, log: SpikeEventLog) {
            self.unit = unit
            self.log = log
        }

        func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>,
                     bus: UInt32, frames: UInt32) -> OSStatus {
            let count = min(Int(frames), buffer.count)
            return buffer.withUnsafeMutableBufferPointer { samples -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: UnsafeMutableRawPointer(samples.baseAddress)))
                let status = AudioUnitRender(unit, flags, timeStamp, bus, UInt32(count), &list)
                guard status == noErr else { return status }
                let start = AudioUnitIO.seconds(ofHostTime: timeStamp.pointee.mHostTime)
                let slice = UnsafeBufferPointer(rebasing: samples[0..<count])
                peak = max(peak, slice.map(abs).max() ?? 0)
                let onsets = detector.scan(slice, firstSampleSeconds: start)
                if !onsets.isEmpty {
                    reportQueue.async { [self] in
                        for onset in onsets { stats.add(ClickTrack.latencyMillis(ofOnsetAt: onset)) }
                        if stats.samples.count >= 5 { report() }
                    }
                }
                return noErr
            }
        }

        func report() {
            reportQueue.async { [self] in
                let summary = stats.summary
                log.record("mic_loopback_latency_ms", ["bursts": summary?.count ?? 0, "peak": Double(peak),
                                                       "min": summary?.min ?? -1, "median": summary?.median ?? -1,
                                                       "max": summary?.max ?? -1])
                stats.reset()
                peak = 0
            }
        }
    }
}
