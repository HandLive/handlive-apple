import Foundation
import HLAppCore
import HLCalls
import HLSMS
import HLTransport

/// Entry point: parses the command line, opens the scratch workspace, sets up `adb forward`, and runs one command.
/// Device-changing work (`pair`, `demo`) runs under the emulator lock when `--lock` is given; Ctrl-C releases it.
@main
@MainActor
enum DevClientMain {
    static func main() async {
        let options: DevOptions
        do {
            options = try DevOptions.parse(Array(CommandLine.arguments.dropFirst()),
                                           environment: ProcessInfo.processInfo.environment)
        } catch is DevOptions.HelpRequested {
            print(DevOptions.usage)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\n\(DevOptions.usage)\n".utf8))
            exit(64)
        }
        let lock = options.lock.map(DeviceLock.init(directory:))
        let traps = SignalTraps { lock?.release() }
        let passed: Bool
        do {
            passed = try await run(options, lock: lock)
        } catch {
            DevConsole.line("error: \(error)")
            passed = false
        }
        lock?.release()
        withExtendedLifetime(traps) {}
        exit(passed ? 0 : 1)
    }

    static func run(_ options: DevOptions, lock: DeviceLock?) async throws -> Bool {
        let workspace = try DevWorkspace(options: options)
        let phone = PhoneDriver(adb: options.adb, serial: options.serial, stepDelay: options.stepDelay)
        DevConsole.line("dev client \(DevLink.short(workspace.keys.deviceId)) “\(options.name)”, scratch "
            + "\(options.scratch.path), phone \(options.serial) at \(options.host):\(options.port)")
        if options.command == .status { return status(workspace) }
        try await phone.forward(local: options.port, remote: options.phonePort)
        if options.command == .pair {
            try await lock?.acquire("pairing the Swift dev client by PIN")
            defer { lock?.release() }
            return try await DevPairing(workspace: workspace, phone: phone, macTiming: options.macTiming).run()
        }
        guard workspace.pairedDevice != nil else {
            DevConsole.line("not paired yet: run `pair` first")
            return false
        }
        let link = try DevLink(workspace: workspace)
        defer { Task { await link.stop() } }
        return try await runSession(options, commands: DevCommands(workspace: workspace, link: link), phone: phone,
                                    lock: lock)
    }

    /// The commands that need the session with the phone.
    static func runSession(_ options: DevOptions, commands: DevCommands, phone: PhoneDriver,
                           lock: DeviceLock?) async throws -> Bool {
        switch options.command {
        case .listen: return await commands.listen(seconds: options.seconds)
        case .answer(let callId): return await commands.callCommand(.answer(.phone), callId: callId)
        case .reject(let callId): return await commands.callCommand(.reject(reply: nil), callId: callId)
        case .end(let callId): return await commands.callCommand(.end, callId: callId)
        case .smsSend(let target, let text): return await commands.smsSend(target: target, text: text)
        case .clipPush(let text): return await commands.clipPush(text)
        case .logSync: return await commands.logSync()
        case .demo, .pair, .status:
            DevConsole.line("\(options.command) is not available in this build")
            return false
        }
    }

    static func status(_ workspace: DevWorkspace) -> Bool {
        guard let record = workspace.pairedDevice else {
            DevConsole.line("not paired")
            return true
        }
        DevConsole.line("paired with “\(record.peerName)” (pair \(DevLink.short(record.pairId))), Security Code "
            + "\(record.securityCode.prefix(4)) \(record.securityCode.suffix(4)), last address "
            + "\(record.lastHost ?? "?"):\(record.lastPort.map(String.init) ?? "?")")
        if let capability = record.peerCapability { DevConsole.line("phone: \(DevLink.summary(capability))") }
        return true
    }
}

/// Ctrl-C and `kill` release the emulator lock before the process ends.
final class SignalTraps {
    private let sources: [DispatchSourceSignal]

    init(onSignal: @escaping @Sendable () -> Void) {
        sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                onSignal()
                exit(130)
            }
            source.resume()
            return source
        }
    }
}
