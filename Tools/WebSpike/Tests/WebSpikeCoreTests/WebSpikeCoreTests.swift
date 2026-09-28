import Testing
@testable import WebSpikeCore

@Suite struct URLNormalizerTests {
    @Test func keepsWebAddressesAndLowercasesSchemeAndHost() {
        let url = URLNormalizer.normalize("  HTTPS://En.Wikipedia.org/wiki/Handoff?x=1#History ")
        #expect(url == NormalizedURL(url: "https://en.wikipedia.org/wiki/Handoff?x=1#History", host: "en.wikipedia.org"))
        #expect(URLNormalizer.normalize("http://localhost:3000/")?.host == "localhost")
        #expect(URLNormalizer.normalize("http://192.168.1.10:8080/a")?.url == "http://192.168.1.10:8080/a")
    }

    @Test(arguments: [
        "about:blank", "favorites://", "chrome://newtab/", "edge://settings", "arc://start", "file:///Users/x/a.html",
        "javascript:alert(1)", "data:text/html,hi", "ftp://example.com/", "safari-resource:/x", "example.com",
        "", "https://", "https://user:pw@example.com/", "https://exa mple.com/", "https://example.com:0/",
        "https://[::1]/", "https://999.1.1.1/", "https://-bad.com/", "https://news/", "https://example.123/",
    ])
    func rejectsWhatTheOtherDeviceCannotOpen(_ raw: String) {
        #expect(URLNormalizer.normalize(raw) == nil)
    }

    @Test func convertsInternationalizedHostsToPunycode() {
        #expect(URLNormalizer.normalize("https://bücher.de/katalog")?.url == "https://xn--bcher-kva.de/katalog")
        #expect(URLNormalizer.normalize("https://аpple.com/")?.host == "xn--pple-43d.com") // Cyrillic "а"
        #expect(URLNormalizer.normalize("https://münchen.de/")?.host == "xn--mnchen-3ya.de")
        #expect(URLNormalizer.normalize("https://ví-dụ.vn/")?.host == "xn--v-d-rma6749a.vn")
        #expect(URLNormalizer.normalize("https://例え.jp/")?.host == "xn--r8jz45g.jp")
    }

    @Test func rejectsAddressesOverEightKibibytes() {
        let base = "https://example.com/?q="
        let fits = base + String(repeating: "a", count: URLNormalizer.maxURLBytes - base.utf8.count)
        #expect(URLNormalizer.normalize(fits)?.url == fits)
        #expect(URLNormalizer.normalize(fits + "a") == nil)
    }
}

@Suite struct BrowserTableTests {
    @Test func findsSupportedBrowsersByBundleID() {
        #expect(BrowserTable.spec(forBundleID: "com.apple.Safari")?.family == .safari)
        #expect(BrowserTable.spec(forBundleID: "com.google.Chrome")?.wireID == "chrome")
        #expect(BrowserTable.spec(forBundleID: "company.thebrowser.Browser")?.family == .arc)
        #expect(BrowserTable.spec(forBundleID: "org.mozilla.firefox") == nil) // no URL scripting (W4)
        #expect(BrowserTable.spec(forBundleID: nil) == nil)
    }

    @Test func wireIDsComeFromTheProtocolList() {
        let protocolIDs: Set = ["chrome", "samsung", "firefox", "edge", "brave", "opera", "vivaldi", "duckduckgo",
                                "safari", "arc", "other"]
        #expect(BrowserTable.all.allSatisfy { protocolIDs.contains($0.wireID) })
        #expect(Set(BrowserTable.all.map(\.bundleID)).count == BrowserTable.all.count)
    }

    @Test func scriptsTargetTheBundleIDAndReadThePrivateValue() {
        for spec in BrowserTable.all {
            let script = BrowserTable.script(for: spec)
            #expect(script.contains("tell application id \"\(spec.bundleID)\""))
            #expect(script.contains("with timeout of 2 seconds"))
        }
        #expect(BrowserTable.script(for: BrowserTable.all[1]).contains("mode of w"))
        #expect(BrowserTable.script(for: BrowserTable.all[0]).contains("bounds of w"))
    }
}

@Suite struct PageReadingTests {
    @Test func chromiumModeDecidesPrivate() {
        #expect(PageReading(url: "u", title: "", mode: "normal").verdict(family: .chromium) == .normal)
        #expect(PageReading(url: "u", title: "", mode: "incognito").verdict(family: .chromium)
            == .privateMode(marker: "mode:incognito"))
        #expect(PageReading(url: "u", title: "", mode: "").verdict(family: .chromium) == .unknown)
        #expect(PageReading(url: "u", title: "", mode: "").verdict(family: .arc) == .unknown)
        #expect(PageReading(url: "u", title: "", mode: "0,25,1440,900").verdict(family: .safari) == .unknown)
    }

    @Test func parsesScriptItemsAndSafariBounds() {
        let reading = PageReading(items: ["https://a.com/", nil, "0, 25, 1440, 900"])
        #expect(reading?.title == "")
        #expect(reading?.safariBounds == WindowBounds(left: 0, top: 25, right: 1440, bottom: 900))
        #expect(PageReading(items: ["a", "b"]) == nil)
        let cgWindow = WindowBounds(originX: 0.4, originY: 25, width: 1440, height: 875)
        #expect(cgWindow.matches(WindowBounds(left: 0, top: 25, right: 1440, bottom: 900)))
        #expect(!cgWindow.matches(WindowBounds(left: 100, top: 25, right: 1440, bottom: 900)))
    }
}

@Suite struct SettleGateTests {
    @Test func reportsOnceWhenStable() {
        var gate = SettleGate<String>(settle: 1.5)
        #expect(gate.observe("a", now: 0) == nil)
        #expect(gate.observe("a", now: 1.4) == nil)
        #expect(gate.observe("a", now: 1.5) == "a")
        #expect(gate.observe("a", now: 3) == nil)
    }

    @Test func changesAndGapsRestartTheClock() {
        var gate = SettleGate<String>(settle: 1.5)
        _ = gate.observe("a", now: 0)
        #expect(gate.observe("b", now: 1) == nil)
        #expect(gate.observe(nil, now: 2) == nil)
        #expect(gate.observe("b", now: 3) == nil)
        #expect(gate.observe("b", now: 4.5) == "b")
        gate.reset()
        #expect(gate.observe("b", now: 5) == nil)
        #expect(gate.observe("b", now: 6.5) == "b")
    }
}

@Suite struct LogLineTests {
    @Test func formatsWithoutSpacesAndSkipsNil() {
        let line = LogLine.format(["ev": "active", "host": "a.com", "x": nil, "reason": "a b=c"])
        #expect(line == "HLWEB ev=active host=a.com reason=a_b_c")
    }

    @Test func hashIsShortAndSalted() {
        let hash = LogLine.hash("https://a.com/secret", salt: "s1")
        #expect(hash.count == 12)
        #expect(hash == LogLine.hash("https://a.com/secret", salt: "s1"))
        #expect(hash != LogLine.hash("https://a.com/secret", salt: "s2"))
    }
}
