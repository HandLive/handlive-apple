import CoreAudio
import Foundation

/// A Core Audio device as the probe reports it. The phone's call audio, once the SCO link is open, may show up as one of
/// these; which name, transport and sample rate it gets is one of the questions the probe answers.
struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transport: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double

    var isBluetooth: Bool { transport.hasPrefix("bluetooth") }

    var summary: [String: Any] {
        ["name": name, "uid": uid, "transport": transport, "in": inputChannels, "out": outputChannels,
         "rate": sampleRate]
    }
}

enum AudioDevices {
    static func all() -> [AudioDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(device)
    }

    static func device(_ id: AudioDeviceID) -> AudioDevice {
        AudioDevice(id: id, name: string(id, kAudioObjectPropertyName) ?? "?",
                    uid: string(id, kAudioDevicePropertyDeviceUID) ?? "?", transport: transport(id),
                    inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                    outputChannels: channels(id, kAudioObjectPropertyScopeOutput), sampleRate: sampleRate(id))
    }

    /// Calls `onChange` on the main queue whenever a device appears or goes away.
    static func observe(_ onChange: @escaping () -> Void) {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            onChange()
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = globalAddress(input ? kAudioHardwarePropertyDefaultInputDevice
                                          : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector,
                                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static let transportNames: [UInt32: String] = [
        kAudioDeviceTransportTypeBuiltIn: "builtIn", kAudioDeviceTransportTypeBluetooth: "bluetooth",
        kAudioDeviceTransportTypeBluetoothLE: "bluetoothLE", kAudioDeviceTransportTypeUSB: "usb",
        kAudioDeviceTransportTypeVirtual: "virtual", kAudioDeviceTransportTypeAggregate: "aggregate",
        kAudioDeviceTransportTypeDisplayPort: "displayPort", kAudioDeviceTransportTypeHDMI: "hdmi",
        kAudioDeviceTransportTypeAirPlay: "airPlay", kAudioDeviceTransportTypeThunderbolt: "thunderbolt",
    ]

    private static func transport(_ id: AudioObjectID) -> String {
        var address = globalAddress(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return "?" }
        return transportNames[type] ?? String(format: "0x%08x", type)
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = globalAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func sampleRate(_ id: AudioObjectID) -> Double {
        var address = globalAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : 0
    }
}
