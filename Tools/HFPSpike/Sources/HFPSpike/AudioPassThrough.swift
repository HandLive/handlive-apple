import AudioToolbox
import AVFoundation
import CoreAudio

/// Plays the call audio the phone sends (the input of `callDevice`) on the Mac's default output, and sends the Mac's
/// default microphone to the phone (the output of `callDevice`), so a tester can judge two-way audio by ear. Use
/// headphones: nothing here cancels echo.
final class AudioPassThrough {
    private let downlink = AVAudioEngine()
    private let uplink = AVAudioEngine()

    init(callDevice: AudioDevice) throws {
        if callDevice.inputChannels > 0 {
            try Self.use(callDevice.id, for: downlink.inputNode)
            downlink.connect(downlink.inputNode, to: downlink.mainMixerNode,
                             format: downlink.inputNode.inputFormat(forBus: 0))
            try downlink.start()
        }
        if callDevice.outputChannels > 0 {
            try Self.use(callDevice.id, for: uplink.outputNode)
            uplink.connect(uplink.inputNode, to: uplink.mainMixerNode, format: uplink.inputNode.inputFormat(forBus: 0))
            try uplink.start()
        }
    }

    func stop() {
        downlink.stop()
        uplink.stop()
    }

    private static func use(_ device: AudioDeviceID, for node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { throw PassThroughError.noAudioUnit }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw PassThroughError.deviceRefused(status) }
    }
}

enum PassThroughError: Error, CustomStringConvertible {
    case noAudioUnit
    case deviceRefused(OSStatus)

    var description: String {
        switch self {
        case .noAudioUnit: "the audio engine has no I/O unit"
        case .deviceRefused(let status): "the I/O unit refused the device (OSStatus \(status))"
        }
    }
}
