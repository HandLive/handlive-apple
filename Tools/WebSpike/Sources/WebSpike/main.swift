import AppKit
import WebSpikeCore

// WebSpike — gate G6 probe for Continue Browsing on the Mac (hub plans/20260928-web-handoff/plan.md W4, W8).
//
//   WebSpike watch [--log FILE] [--interval 1.5]   follow the frontmost browser and log HLWEB lines
//   WebSpike permissions                            Automation state for each running browser, without prompting
//   WebSpike ask <browser>                          ask for Automation now (shows the TCC prompt once)
//   WebSpike once <browser>                         read the browser's front window once
//   WebSpike ax-dump [--delay 5] [--out FILE]       accessibility tree of the frontmost browser window (redacted)
//
// <browser>: safari, chrome, edge, brave, arc, vivaldi, opera.

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func spec(_ wireID: String?) -> BrowserSpec {
    guard let found = BrowserTable.all.first(where: { $0.wireID == wireID }) else {
        let ids = BrowserTable.all.map(\.wireID).joined(separator: ", ")
        FileHandle.standardError.write(Data("unknown browser; one of: \(ids)\n".utf8))
        exit(64)
    }
    return found
}

let log = EventLog(path: option("--log"))

switch arguments.first {
case "watch":
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let watcher = BrowserWatcher(log: log, interval: option("--interval").flatMap(Double.init) ?? 1.5)
    watcher.start()
    signal(SIGINT) { _ in exit(0) }
    application.run()

case "permissions":
    for browser in BrowserTable.all {
        let (permission, status) = AppleEventReader.permission(for: browser.bundleID)
        log.write(["ev": "permission", "browser": browser.wireID, "automation": permission.rawValue, "status": status])
    }

case "ask":
    let browser = spec(arguments.dropFirst().first)
    let (permission, status) = AppleEventReader.permission(for: browser.bundleID, ask: true)
    log.write(["ev": "permission", "browser": browser.wireID, "automation": permission.rawValue, "status": status])

case "once":
    let browser = spec(arguments.dropFirst().first)
    switch AppleEventReader().read(browser) {
    case let .failure(code, milliseconds):
        log.write(["ev": "error", "browser": browser.wireID, "code": code, "script_ms": milliseconds])
    case let .reading(reading, milliseconds):
        let url = URLNormalizer.normalize(reading.url)
        log.write([
            "ev": "once", "browser": browser.wireID, "host": url?.host, "supported": url != nil,
            "hash": url.map { LogLine.hash($0.url, salt: log.salt) },
            "private": reading.verdict(family: browser.family).logValue,
            "mode": browser.family == .safari ? nil : reading.mode, "title_len": reading.title.count,
            "script_ms": milliseconds,
        ])
    }

case "ax-dump":
    let delay = option("--delay").flatMap(Double.init) ?? 5
    FileHandle.standardError.write(Data("bring the browser window to the front within \(delay) s…\n".utf8))
    Thread.sleep(forTimeInterval: delay)
    AXDump.run(out: option("--out"), log: log)

default:
    let usage = """
    usage: WebSpike watch [--log FILE] [--interval 1.5] | permissions | ask <browser> | once <browser> |
           ax-dump [--delay 5] [--out FILE]
    browsers: \(BrowserTable.all.map(\.wireID).joined(separator: ", "))

    """
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 0 : 64)
}
