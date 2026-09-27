import Foundation
import HLAppCore
import HLTransport

/// The dev client as the pairing sheet's host: its identity, where the pair is stored, no relay rendezvous.
@MainActor
final class DevPairingHost: PairingHost {
    let workspace: DevWorkspace
    private(set) var pairedName: String?

    init(workspace: DevWorkspace) {
        self.workspace = workspace
    }

    func pairingIdentity() -> PairingIdentity? { workspace.pairingIdentity() }
    var pairingDeviceName: String { workspace.device.name }
    var pairingRelay: RelayServices? { nil }

    func completePairing(_ result: PairingResult) throws {
        try workspace.storePair(result)
    }

    func paired(_ name: String) {
        pairedName = name
    }
}

/// `pair`: PAIR-01 with a PIN, as the Mac runs it — the apps' `PairingController` makes the PIN and runs
/// `PairingSearch` and `PairingExchange` over the real `WebSocketConnector` — while the phone's side is typed into the
/// emulator. The phone's PIN window becomes visible to the search after the PIN is typed (A3 → A4); with
/// `macTiming`, as soon as the phone opens it on "Enter PIN", which is when a real Mac would see TXT `pm = 1`.
@MainActor
struct DevPairing {
    let workspace: DevWorkspace
    let phone: PhoneDriver
    var macTiming = false
    var timeout: Duration = .seconds(150)

    func run() async throws -> Bool {
        let options = workspace.options
        let discovery = ForwardedDiscovery(host: options.host, port: options.port)
        let search = PairingSearch(discovery: discovery,
                                   connector: ForwardedConnector(host: options.host, port: options.port))
        let host = DevPairingHost(workspace: workspace)
        let controller = PairingController(host: host, search: search) { host.paired($0) }
        controller.start()
        controller.usePIN()
        defer { controller.stop() }
        DevConsole.line("PIN on this Mac: \(controller.pin), valid for \(controller.secondsLeft) s")
        let script = PhonePairingScript(phone: phone)
        try await script.openPinEntry()
        if macTiming {
            discovery.announcePinWindow()
            try await Task.sleep(for: .seconds(4))
            let usable = try await script.pinFieldVisible()
            DevConsole.result(usable, "PIN field while the Mac is already connected",
                              usable ? "still there" : "the phone replaced it with “Pairing…”; the PIN cannot be typed")
            guard usable else {
                try await script.cancel()
                return false
            }
        }
        try await script.typePin(controller.pin)
        discovery.announcePinWindow()
        let started = ContinuousClock.now
        guard try await waitForPair(host, controller: controller) else { return false }
        DevConsole.result(true, "pairing", "paired with \(DevConsole.name(host.pairedName)) in "
            + "\(started.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds])))")
        return try await compareSecurityCodes(script)
    }

    private func waitForPair(_ host: DevPairingHost, controller: PairingController) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastProgress = controller.progress
        while host.pairedName == nil {
            if controller.progress != lastProgress {
                lastProgress = controller.progress
                DevConsole.line("pairing: \(lastProgress)")
            }
            if let notice = controller.notice, notice != .phoneNotFound {
                DevConsole.result(false, "pairing", "the pairing sheet says \(notice)")
                return false
            }
            guard ContinuousClock.now < deadline else {
                DevConsole.result(false, "pairing", "no pair within \(timeout)")
                return false
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// PAIR-02 field 10 on both sides: the code this Mac computed from the attestation, and the one on the phone.
    private func compareSecurityCodes(_ script: PhonePairingScript) async throws -> Bool {
        guard let record = workspace.pairedDevice else { return false }
        DevConsole.line("Security Code on this Mac: \(record.securityCode.prefix(4)) \(record.securityCode.suffix(4))")
        let shown = try await script.readSecurityCode()
        DevConsole.line("Security Code on the phone: \(shown)")
        let same = shown.replacingOccurrences(of: " ", with: "").lowercased() == record.securityCode
        DevConsole.result(same, "Security Code", same ? "the same on both devices" : "different codes")
        try await script.finish()
        return same
    }
}

/// The phone's side of PIN pairing in the HandLive app on the emulator, found by the texts of the English UI.
struct PhonePairingScript {
    static let app = "app.handlive.android/.MainActivity"
    let phone: PhoneDriver

    /// Devices → "Add Device" → "Enter PIN": the phone opens its PIN window (TXT `pm = 1`).
    func openPinEntry() async throws {
        try await phone.run(["shell", "am", "start", "-n", Self.app])
        try await Task.sleep(for: phone.stepDelay)
        if try await !phone.dump().contains(where: { $0.text == "Add Device" }) {
            // The tab bar's "Devices" is the lower of the two (the other one is the screen title).
            let tab = try await phone.dump().filter { $0.text == "Devices" }.max { $0.center.y < $1.center.y }
            if let tab { try await phone.tap(tab) }
        }
        try await phone.tap(text: "Add Device")
        try await phone.tap(text: "Enter PIN")
        _ = try await phone.waitFor(text: "Type the 6-digit PIN shown on your Mac or iPhone.")
    }

    func pinFieldVisible() async throws -> Bool {
        try await phone.dump().contains { $0.className == "android.widget.EditText" }
    }

    /// Types the digits one by one; the phone submits at the sixth.
    func typePin(_ pin: String) async throws {
        let field = try await phone.waitFor("the PIN field") { $0.className == "android.widget.EditText" }
        try await phone.tap(field)
        for digit in pin {
            try await phone.run(["shell", "input", "keyevent", "KEYCODE_\(digit)"])
            try await Task.sleep(for: .milliseconds(300))
        }
        _ = try await phone.waitFor(text: "Pairing…")
    }

    func readSecurityCode() async throws -> String {
        _ = try await phone.waitFor(text: "Security Code", timeout: .seconds(60))
        let code = try await phone.waitFor("the Security Code") {
            $0.text.range(of: #"^[0-9a-f]{4} [0-9a-f]{4}$"#, options: .regularExpression) != nil
        }
        return code.text
    }

    func finish() async throws {
        try await phone.tap(text: "Done")
    }

    func cancel() async throws {
        try await phone.tap(text: "Cancel")
    }
}
