import Foundation

/// `adb` for one emulator (`-s <serial>` always): shell input, `uiautomator dump`, `adb emu` console commands and
/// `adb forward`. Every call has a time limit; UI steps are paced so a person can follow them in the emulator window.
struct PhoneDriver: Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let adb: String
    let serial: String
    let stepDelay: Duration

    /// Runs `adb -s <serial> <arguments>` and returns its standard output.
    @discardableResult
    func run(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> String {
        try await Self.execute(adb, ["-s", serial] + arguments, timeout: timeout)
    }

    /// `adb forward tcp:<local> tcp:<remote>` (host side only).
    func forward(local: UInt16, remote: UInt16) async throws {
        try await run(["forward", "tcp:\(local)", "tcp:\(remote)"])
    }

    /// An emulator console command through adb, e.g. `gsm call 5550100`; the console answers `OK` or `KO: …`.
    @discardableResult
    func console(_ command: String) async throws -> String {
        let output = try await run(["emu"] + command.split(separator: " ").map(String.init))
        if output.contains("KO") { throw Failure(description: "emu \(command): \(output)") }
        return output
    }

    // MARK: - UI

    func dump() async throws -> [UINode] {
        try await run(["shell", "uiautomator", "dump", "/sdcard/hl-devclient-ui.xml"])
        let xml = try await run(["exec-out", "cat", "/sdcard/hl-devclient-ui.xml"])
        return UINode.parse(xml)
    }

    /// Waits until a node matches, dumping the screen twice a second.
    func waitFor(_ description: String, timeout: Duration = .seconds(15),
                 where matches: @escaping (UINode) -> Bool) async throws -> UINode {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let node = try await dump().first(where: matches) { return node }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Failure(description: "the phone never showed \(description)")
    }

    func waitFor(text: String, timeout: Duration = .seconds(15)) async throws -> UINode {
        try await waitFor("“\(text)”", timeout: timeout) { $0.text == text || $0.contentDescription == text }
    }

    /// Taps the node's center, then pauses for `stepDelay`.
    func tap(_ node: UINode) async throws {
        try await run(["shell", "input", "tap", "\(node.center.x)", "\(node.center.y)"])
        try await Task.sleep(for: stepDelay)
    }

    func tap(text: String, timeout: Duration = .seconds(15)) async throws {
        try await tap(try await waitFor(text: text, timeout: timeout))
    }

    /// Types digits or plain words (spaces are sent as `%s`).
    func type(_ text: String) async throws {
        try await run(["shell", "input", "text", text.replacingOccurrences(of: " ", with: "%s")])
        try await Task.sleep(for: stepDelay)
    }

    func key(_ code: String) async throws {
        try await run(["shell", "input", "keyevent", code])
        try await Task.sleep(for: stepDelay)
    }

    // MARK: - Processes

    static func execute(_ tool: String, _ arguments: [String], timeout: Duration) async throws -> String {
        let run = ToolRun(tool: tool, arguments: arguments)
        let (status, text) = try await run.finish(within: timeout)
        guard status == 0 else {
            throw Failure(description: "\(URL(fileURLWithPath: tool).lastPathComponent) \(arguments.joined(separator: " ")) "
                + "failed (\(status)): \(text.prefix(300))")
        }
        return text
    }
}

/// One child process whose output goes to a temporary file: a daemon it may start keeps no pipe open, so waiting for
/// the tool never hangs; the tool is stopped when the time limit passes.
private final class ToolRun: @unchecked Sendable {
    let process = Process()
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hl-devclient-\(UUID().uuidString).out")

    init(tool: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
    }

    func finish(within timeout: Duration) async throws -> (Int32, String) {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = handle
        process.standardError = handle
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.inSeconds) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return (status, String(bytes: data, encoding: .utf8) ?? "")
    }
}

extension Duration {
    /// Seconds as a `Double`, for Dispatch deadlines.
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// One node of a `uiautomator dump`.
struct UINode: Sendable, Equatable {
    let text: String
    let contentDescription: String
    let className: String
    let resourceId: String
    let clickable: Bool
    let center: (x: Int, y: Int)

    static func == (lhs: UINode, rhs: UINode) -> Bool {
        lhs.text == rhs.text && lhs.contentDescription == rhs.contentDescription && lhs.className == rhs.className
            && lhs.center.x == rhs.center.x && lhs.center.y == rhs.center.y
    }

    static func parse(_ xml: String) -> [UINode] {
        let collector = UINodeCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.parse()
        return collector.nodes
    }
}

private final class UINodeCollector: NSObject, XMLParserDelegate {
    var nodes: [UINode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard elementName == "node" else { return }
        let numbers = (attributes["bounds"] ?? "").split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count == 4 else { return }
        nodes.append(UINode(text: attributes["text"] ?? "", contentDescription: attributes["content-desc"] ?? "",
                            className: attributes["class"] ?? "", resourceId: attributes["resource-id"] ?? "",
                            clickable: attributes["clickable"] == "true",
                            center: ((numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2)))
    }
}
