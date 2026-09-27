import Foundation

/// Command line of the dev client: `HandLiveDevClient <command> [arguments] --scratch <dir> [options]`.
struct DevOptions {
    enum Command: Equatable {
        case pair
        case status
        case listen
        case answer(callId: String)
        case reject(callId: String)
        case end(callId: String)
        case smsSend(target: String, text: String)
        case clipPush(text: String)
        case logSync
        case demo
    }

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    /// `--help`, `-h` or `help`: the usage text, and success.
    struct HelpRequested: Error {}

    var command: Command
    /// Keys, settings, the pair and the database: a directory outside the repository.
    var scratch: URL
    var host = "127.0.0.1"
    /// Host port that `adb forward` maps to the phone's 47800.
    var port: UInt16 = 47830
    var phonePort: UInt16 = 47800
    var serial = "emulator-5554"
    var adb: String
    /// The name the phone shows for this client.
    var name = "HandLive Dev Mac"
    /// A lock directory shared with other users of the emulator, taken around device-changing steps.
    var lock: URL?
    /// Pause between UI steps on the phone, so a person can follow them in the emulator window.
    var stepDelay: Duration = .seconds(1)
    /// `listen` stops after this many seconds; `nil` runs until interrupted.
    var seconds: Int?
    /// `pair`: show the PIN window to the search as soon as the phone opens it (on "Enter PIN"), which is when a real
    /// Mac sees TXT `pm = 1`, instead of after the PIN is typed.
    var macTiming = false

    static let flags: Set<String> = ["mac-timing"]

    static let usage = """
    usage: HandLiveDevClient <command> --scratch <dir> [options]
    commands:
      pair                         pair with the phone using a PIN (drives the emulator's UI)
      status                       show the stored pair and its Security Code
      listen                       print call_event, sms/new and sms/status as they arrive
      answer|reject|end <call_id>  send a call command through the call controller
      sms-send <thread|number> <text>
      clip-push <text>
      log-sync                     sync the call log and print it (numbers masked)
      demo                         scripted calls and SMS on the emulator, PASS/FAIL per step
    options:
      --scratch <dir>   keys, settings, pair and database (never inside the repository)
      --host <h>        default 127.0.0.1        --port <p>       default 47830 (adb forward to 47800)
      --serial <s>      default emulator-5554    --adb <path>     default $ANDROID_HOME/platform-tools/adb
      --name <n>        name shown on the phone  --lock <dir>     device lock taken around UI and emulator steps
      --step-delay <s>  pause between UI steps, default 1   --seconds <n>  listen time limit
      --mac-timing      pair: let the Mac connect as soon as the phone opens its PIN window, as a real Mac does
    """

    static func parse(_ arguments: [String], environment: [String: String]) throws -> DevOptions {
        if arguments.isEmpty || arguments.contains(where: { ["--help", "-h", "help"].contains($0) }) {
            throw HelpRequested()
        }
        var positional: [String] = []
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), flags.contains(String(argument.dropFirst(2))) {
                values[String(argument.dropFirst(2))] = "true"
                index += 1
            } else if argument.hasPrefix("--") {
                guard index + 1 < arguments.count else { throw UsageError(description: "\(argument) needs a value") }
                values[String(argument.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                positional.append(argument)
                index += 1
            }
        }
        guard let scratchPath = values["scratch"] else { throw UsageError(description: "--scratch is required") }
        let sdk = environment["ANDROID_HOME"] ?? "/opt/homebrew/share/android-commandlinetools"
        var options = DevOptions(command: try command(positional),
                                 scratch: URL(fileURLWithPath: scratchPath, isDirectory: true).standardizedFileURL,
                                 adb: values["adb"] ?? "\(sdk)/platform-tools/adb")
        try options.apply(values)
        return options
    }

    private mutating func apply(_ values: [String: String]) throws {
        if let host = values["host"] { self.host = host }
        if let port = values["port"] { self.port = try Self.number(port, "--port") }
        if let serial = values["serial"] { self.serial = serial }
        if let name = values["name"] { self.name = name }
        macTiming = values["mac-timing"] == "true"
        if let lock = values["lock"] { self.lock = URL(fileURLWithPath: lock, isDirectory: true) }
        if let delay = values["step-delay"], let seconds = Double(delay) { stepDelay = .milliseconds(Int(seconds * 1000)) }
        if let text = values["seconds"] {
            let limit: Int = try Self.number(text, "--seconds")
            seconds = limit
        }
    }

    private static func number<T: FixedWidthInteger>(_ text: String, _ name: String) throws -> T {
        guard let value = T(text) else { throw UsageError(description: "\(name) must be a number") }
        return value
    }

    private static let simpleCommands: [String: Command] = [
        "pair": .pair, "status": .status, "listen": .listen, "log-sync": .logSync, "demo": .demo,
    ]

    private static func command(_ words: [String]) throws -> Command {
        guard let name = words.first else { throw UsageError(description: "a command is required") }
        let rest = Array(words.dropFirst())
        if rest.isEmpty, let simple = simpleCommands[name] { return simple }
        switch (name, rest.count) {
        case ("answer", 1): return .answer(callId: rest[0])
        case ("reject", 1): return .reject(callId: rest[0])
        case ("end", 1): return .end(callId: rest[0])
        case ("sms-send", 2...): return .smsSend(target: rest[0], text: rest.dropFirst().joined(separator: " "))
        case ("clip-push", 1...): return .clipPush(text: rest.joined(separator: " "))
        default: throw UsageError(description: "unknown command or wrong arguments: \(words.joined(separator: " "))")
        }
    }
}
