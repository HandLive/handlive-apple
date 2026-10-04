import Foundation
import Testing
@testable import HLProtocol

@Suite("HtmlClipSanitizer theo vector clipboard-html.json")
struct HtmlClipSanitizerVectorTests {
    private struct Case {
        let name: String
        let input: String
        let output: String
    }

    private func cases() throws -> [Case] {
        let url = RepoFiles.vectorsDirectory.appendingPathComponent("clipboard-html.json")
        let object = try #require(try RepoFiles.json(at: url) as? [String: Any])
        let list = try #require(object["cases"] as? [[String: Any]])
        return try list.map {
            Case(name: try $0.string("name"), input: try $0.string("input"), output: try $0.string("output"))
        }
    }

    @Test("Mọi case cho đúng output từng byte")
    func everyCaseMatches() throws {
        let all = try cases()
        #expect(all.count >= 30)
        for item in all {
            #expect(HtmlClipSanitizer.sanitize(item.input) == item.output, "\(item.name)")
        }
    }

    @Test("Đầu ra không còn script, javascript: hay thuộc tính on…")
    func hostileInputLeavesNothingActive() {
        let hostile = "<img src=x onerror=alert(1)><a href=\"JaVaScRiPt:alert(1)\" onclick=\"x\">a</a>"
            + "<SCRIPT >alert(1)</SCRIPT ><p onload='x' title=\"a>b\">k</p><!-- <script> -->"
        let output = HtmlClipSanitizer.sanitize(hostile).lowercased()
        #expect(!output.contains("<script"))
        #expect(!output.contains("javascript:"))
        #expect(!output.contains("onerror"))
        #expect(!output.contains("onclick"))
        #expect(!output.contains("onload"))
        #expect(HtmlClipSanitizer.sanitize(hostile) == "<a>a</a><p>k</p>")
    }

    @Test("Ký tự nhiều byte đi qua nguyên vẹn")
    func keepsMultibyteText() {
        #expect(HtmlClipSanitizer.sanitize("<p>Hẹn 3h 🙂</p>") == "<p>Hẹn 3h 🙂</p>")
    }
}
