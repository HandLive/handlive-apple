import AudioToolbox
import CoreAudio
import Foundation

/// Core Audio helpers for the microphone half of the spike: device lookup by UID (CAM-01 API 4) and AUHAL units bound
/// to one device, in 48 kHz mono Float32 (CAM-01 API 4 rule 2).
enum AudioUnitIO {
    struct Failure: Error, CustomStringConvertible {
        let call: String
        let status: OSStatus
        var description: String { "\(call) failed: \(status)" }
    }

    static let sampleRate = 48_000.0

    /// `kAudioHardwarePropertyTranslateUIDToDevice`; `nil` when no device has that UID.
    static func device(withUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// A value of `kAudioDevicePropertyIsHidden` (hidden) or `kAudioDevicePropertyDeviceIsRunningSomewhere`.
    static func uint32(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static var monoFloatFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                                        | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    /// An AUHAL unit on `device`: output only when `input` is false, input only when true.
    static func makeHALUnit(device: AudioObjectID, input: Bool) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure(call: "AUHAL", status: -1) }
        var unitOut: AudioUnit?
        try check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &unitOut))
        guard let unit = unitOut else { throw Failure(call: "AudioComponentInstanceNew", status: -1) }
        if input {
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
        }
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)
        // The client side of the unit: output scope of bus 1 when reading, input scope of bus 0 when playing.
        try set(unit, kAudioUnitProperty_StreamFormat, input ? kAudioUnitScope_Output : kAudioUnitScope_Input,
                input ? 1 : 0, monoFloatFormat)
        return unit
    }

    static func set<Value>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                           _ element: AudioUnitElement, _ value: Value) throws {
        let status = withUnsafePointer(to: value) {
            AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<Value>.size))
        }
        try check("AudioUnitSetProperty(\(property))", status)
    }

    static func check(_ call: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure(call: call, status: status) }
    }

    /// Host ticks → seconds.
    static func seconds(ofHostTime hostTime: UInt64) -> Double {
        Double(hostTime) * timebase
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
}
