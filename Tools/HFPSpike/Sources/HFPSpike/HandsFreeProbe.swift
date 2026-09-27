import Foundation
import IOBluetooth

/// Connects to a paired phone in the hands-free role and reports what happens: the service-level connection and its
/// features, the phone's indicators, calls, the SCO link and the Core Audio device that appears with it. Timings are in
/// milliseconds on the monotonic clock. Numbers and names from the phone are reported only as present or absent.
final class HandsFreeProbe: NSObject, IOBluetoothHandsFreeDeviceDelegate {
    private let log: EventLog
    private let handsFree: IOBluetoothHandsFreeDevice
    private let routeAudio: Bool
    private var connectRequestedAt: Double?
    private var scoRequestedAt: Double?
    private var scoOpenedAt: Double?
    private var devicesBeforeSCO: [AudioDevice] = []
    private var passThrough: AudioPassThrough?

    init(device: IOBluetoothDevice, log: EventLog, routeAudio: Bool, features: UInt32?) {
        self.log = log
        self.routeAudio = routeAudio
        handsFree = IOBluetoothHandsFreeDevice(device: device, delegate: nil)
        super.init()
        handsFree.delegate = self
        if let features { handsFree.supportedFeatures = features }
    }

    func start() {
        log.event("probe_start", ["hf_features": Int(handsFree.supportedFeatures),
                                  "phone_is_hfp_gateway": handsFree.device.isHandsFreeAudioGateway])
        devicesBeforeSCO = AudioDevices.all()
        AudioDevices.observe { [weak self] in self?.audioDevicesChanged() }
        connectRequestedAt = log.elapsedMs
        handsFree.connect()
    }

    /// One line typed by the tester; an unknown command prints the list.
    func handle(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let command = parts.first else { return }
        log.event("command", ["command": command])
        guard let run = Self.commands[command] else { return Self.printHelp() }
        run(self, Array(parts.dropFirst()))
    }

    private static let commands: [String: (HandsFreeProbe, [String]) -> Void] = [
        "a": { probe, _ in probe.handsFree.acceptCall() },
        "e": { probe, _ in probe.handsFree.endCall() },
        "c": { probe, _ in probe.requestSCO { $0.transferAudioToComputer() } },
        "p": { probe, _ in probe.handsFree.transferAudioToPhone() },
        "o": { probe, _ in probe.requestSCO { $0.connectSCO() } },
        "x": { probe, _ in probe.handsFree.disconnectSCO() },
        "m": { probe, _ in probe.handsFree.isInputMuted.toggle() },
        "h": { probe, _ in probe.handsFree.holdCall() },
        "l": { probe, _ in probe.handsFree.currentCallList() },
        "d": { probe, digits in digits.joined().forEach { probe.handsFree.sendDTMF(String($0)) } },
        "s": { probe, _ in probe.reportState() },
        "q": { probe, _ in probe.quit() },
    ]

    static func printHelp() {
        print("""
        a answer · e end · c audio to the Mac · p audio to the phone · o open SCO · x close SCO · m mute the Mac mic
        h hold · l list calls · d <digits> DTMF · s state · q quit
        """)
    }

    private func requestSCO(_ request: (IOBluetoothHandsFreeDevice) -> Void) {
        devicesBeforeSCO = AudioDevices.all()
        scoRequestedAt = log.elapsedMs
        request(handsFree)
    }

    private func reportState() {
        let names = [IOBluetoothHandsFreeIndicatorService, IOBluetoothHandsFreeIndicatorCall,
                     IOBluetoothHandsFreeIndicatorCallSetup, IOBluetoothHandsFreeIndicatorCallHeld,
                     IOBluetoothHandsFreeIndicatorSignal, IOBluetoothHandsFreeIndicatorRoam,
                     IOBluetoothHandsFreeIndicatorBattChg]
        var indicators: [String: Int] = [:]
        for name in names { indicators[name] = Int(handsFree.indicator(name)) }
        log.event("state", ["connected": handsFree.isConnected, "sco": handsFree.isSCOConnected(),
                            "indicators": indicators, "input_muted": handsFree.isInputMuted,
                            "phone_features": Int(handsFree.deviceSupportedFeatures),
                            "phone_hold_modes": Int(handsFree.deviceCallHoldModes)])
    }

    private func quit() {
        passThrough?.stop()
        if handsFree.isSCOConnected() { handsFree.disconnectSCO() }
        handsFree.disconnect()
        log.event("probe_end")
        exit(0)
    }

    private func audioDevicesChanged() {
        let now = AudioDevices.all()
        let added = now.filter { device in !devicesBeforeSCO.contains { $0.uid == device.uid } }
        let removed = devicesBeforeSCO.filter { device in !now.contains { $0.uid == device.uid } }
        var fields: [String: Any] = ["added": added.map(\.summary), "removed": removed.map(\.summary)]
        if let scoOpenedAt { fields["ms_after_sco_open"] = log.elapsedMs - scoOpenedAt }
        log.event("audio_devices_changed", fields)
        guard routeAudio, passThrough == nil, let callDevice = added.first(where: \.isBluetooth) ?? added.first
        else { return }
        startPassThrough(callDevice)
    }

    private func startPassThrough(_ device: AudioDevice) {
        do {
            passThrough = try AudioPassThrough(callDevice: device)
            log.event("route_started", ["device": device.summary])
        } catch {
            log.event("route_failed", ["device": device.summary, "error": String(describing: error)])
        }
    }

    // MARK: - IOBluetoothHandsFreeDelegate

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        var fields: [String: Any] = ["status": status?.intValue ?? -1,
                                     "phone_features": Int(handsFree.deviceSupportedFeatures),
                                     "phone_hold_modes": Int(handsFree.deviceCallHoldModes)]
        if let connectRequestedAt { fields["ms"] = log.elapsedMs - connectRequestedAt }
        log.event("slc_connected", fields)
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        log.event("slc_disconnected", ["status": status?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        scoOpenedAt = log.elapsedMs
        var fields: [String: Any] = ["status": status?.intValue ?? -1]
        if let scoRequestedAt { fields["ms"] = log.elapsedMs - scoRequestedAt }
        log.event("sco_opened", fields)
        // A device that appeared together with the SCO link may already be there; a later one comes as a change.
        audioDevicesChanged()
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        passThrough?.stop()
        passThrough = nil
        scoOpenedAt = nil
        log.event("sco_closed", ["status": status?.intValue ?? -1])
    }

    // MARK: - IOBluetoothHandsFreeDeviceDelegate

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isServiceAvailable: NSNumber!) {
        log.event("indicator", ["service": isServiceAvailable?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive: NSNumber!) {
        log.event("indicator", ["call": isCallActive?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode: NSNumber!) {
        log.event("indicator", ["callsetup": callSetupMode?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callHoldState: NSNumber!) {
        log.event("indicator", ["callheld": callHoldState?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, signalStrength: NSNumber!) {
        log.event("indicator", ["signal": signalStrength?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isRoaming: NSNumber!) {
        log.event("indicator", ["roam": isRoaming?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, batteryCharge: NSNumber!) {
        log.event("indicator", ["battchg": batteryCharge?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        log.event("incoming_call", ["number_present": !(number ?? "").isEmpty])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt: NSNumber!) {
        log.event("ring", ["attempt": ringAttempt?.intValue ?? -1])
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall: [AnyHashable: Any]!) {
        let call = currentCall ?? [:]
        let keep = [IOBluetoothHandsFreeCallIndex, IOBluetoothHandsFreeCallDirection, IOBluetoothHandsFreeCallStatus,
                    IOBluetoothHandsFreeCallMode, IOBluetoothHandsFreeCallMultiparty]
        var fields: [String: Any] = [:]
        for key in keep { if let value = call[key] as? NSNumber { fields[key] = value.intValue } }
        fields["number_present"] = call[IOBluetoothHandsFreeCallNumber] != nil
        log.event("current_call", fields)
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode: String!) {
        // Result codes can carry numbers (+CLIP, +CLCC): only the code's name is kept.
        let code = (unhandledResultCode ?? "").split(separator: ":").first.map(String.init) ?? ""
        log.event("unhandled_result", ["code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
}
