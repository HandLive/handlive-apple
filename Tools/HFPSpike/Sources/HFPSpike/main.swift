import Foundation
import IOBluetooth

// hfp-spike list | audio-devices | probe <phone address> [--route] [--features <n>] [--log <file.jsonl>]
let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func usage() {
    print("""
    usage: HFPSpike list                      paired Bluetooth devices, and which are phones with hands-free audio
           HFPSpike audio-devices             Core Audio devices (name, transport, channels, sample rate)
           HFPSpike probe <address> [--route] [--features <n>] [--log <file.jsonl>]
                                              connect as hands-free, then type commands (help lists them)
    """)
}

let log = EventLog(path: option("--log"))
log.event("host", ["macos": ProcessInfo.processInfo.operatingSystemVersionString, "model": hardwareModel()])

switch arguments.first {
case "list":
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    for device in paired {
        log.event("paired_device", ["name": device.nameOrAddress ?? "?", "address": device.addressString ?? "?",
                                    "connected": device.isConnected(), "hfp_gateway": device.isHandsFreeAudioGateway,
                                    "major_class": Int(device.deviceClassMajor)])
    }
    exit(0)
case "audio-devices":
    for device in AudioDevices.all() { log.event("audio_device", device.summary) }
    exit(0)
case "probe":
    guard arguments.count >= 2, let device = IOBluetoothDevice(addressString: arguments[1]) else {
        usage()
        exit(2)
    }
    let probe = HandsFreeProbe(device: device, log: log, routeAudio: arguments.contains("--route"),
                               features: option("--features").flatMap { UInt32($0) })
    HandsFreeProbe.printHelp()
    probe.start()
    FileHandle.standardInput.readabilityHandler = { handle in
        guard let text = String(bytes: handle.availableData, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            for line in text.split(separator: "\n") { probe.handle(line.trimmingCharacters(in: .whitespaces)) }
        }
    }
    RunLoop.main.run()
default:
    usage()
    exit(arguments.isEmpty ? 0 : 2)
}

func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}
