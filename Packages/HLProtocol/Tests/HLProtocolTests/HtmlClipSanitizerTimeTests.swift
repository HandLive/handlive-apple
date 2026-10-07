import Foundation
import Testing
@testable import HLProtocol

/// The sanitizer runs on the main thread when a copy is read (Mac and iOS), so its time must grow with the input, not
/// with its square: a `<` that never completes a tag must not cost a scan to the end of the input. Each input is about
/// 1 MiB and must take under 5 s (a linear sanitizer takes under 1 s in a Debug build); the measured time is printed
/// even when the test passes, and the time limit fails a quadratic sanitizer instead of letting it hang the run.
@Suite("HtmlClipSanitizer in linear time")
struct HtmlClipSanitizerTimeTests {
    @Test("1 MiB of <a without any > is sanitized in under 5 s", .timeLimit(.minutes(1)))
    func noClosingBracket() {
        expectQuick("<a repeated", String(repeating: "<a", count: 524_288),
                    becomes: String(repeating: "&lt;a", count: 524_288))
    }

    @Test("1 MiB of <a\"x\" then '>: a quote that never closes hides the > and still takes under 5 s",
          .timeLimit(.minutes(1)))
    func quoteNeverClosed() {
        expectQuick("<a\"x\" repeated, then '>", String(repeating: "<a\"x\"", count: 209_715) + "'>",
                    becomes: String(repeating: "&lt;a\"x\"", count: 209_715) + "'>")
    }

    @Test("1 MiB of <a '\"' then \">: quotes nested in quotes, the last one never closed, takes under 5 s",
          .timeLimit(.minutes(1)))
    func nestedQuotes() {
        expectQuick("<a '\"' repeated, then \">", String(repeating: "<a '\"'", count: 174_763) + "\">",
                    becomes: String(repeating: "&lt;a '\"'", count: 174_763) + "\">")
    }

    /// An odd number of `"`: the first tag start meets a quote that never closes, the second one closes at the end.
    @Test("1 MiB of <a\" an odd number of times, then >: one tag at the end, under 5 s", .timeLimit(.minutes(1)))
    func oddQuoteCount() {
        expectQuick("<a\" odd times, then >", String(repeating: "<a\"", count: 349_525) + ">", becomes: "&lt;a\"<a>")
    }

    private func expectQuick(_ name: String, _ input: String, becomes output: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let clock = ContinuousClock()
        var result = ""
        let elapsed = clock.measure { result = HtmlClipSanitizer.sanitize(input) }
        print("HtmlClipSanitizer \(name): \(input.utf8.count) bytes in \(elapsed)")
        #expect(elapsed < .seconds(5), "\(elapsed)", sourceLocation: sourceLocation)
        #expect(result == output, sourceLocation: sourceLocation)
    }
}
