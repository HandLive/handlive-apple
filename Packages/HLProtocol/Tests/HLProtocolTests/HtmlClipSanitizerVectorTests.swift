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
            // Swift String equality is canonical equivalence, not bytes: compare the UTF-8 bytes.
            #expect(Array(HtmlClipSanitizer.sanitize(item.input).utf8) == Array(item.output.utf8), "\(item.name)")
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

    @Test("Đầu vào có dấu ngoặc nhọn hở và mXSS không để lại thẻ hay thuộc tính hoạt động")
    func unbalancedAndMutationInputsLeaveNothingActive() {
        let inputs = [
            "<img src=x onerror=alert(1) \"<p>a</p>",
            "<p><style><img src=\"</style><img src=x onerror=alert(1)//\"></p>"
        ]
        for input in inputs {
            let output = HtmlClipSanitizer.sanitize(input).lowercased()
            #expect(!output.contains("<img"), "\(input)")
            #expect(!output.contains("<script"), "\(input)")
            // `onerror=` may survive only as escaped text, never inside a tag.
            for part in output.components(separatedBy: "<").dropFirst() {
                #expect(!part.prefix { $0 != ">" }.contains("onerror="), "\(input)")
            }
        }
    }

    @Test("Ký tự nhiều byte đi qua nguyên vẹn")
    func keepsMultibyteText() {
        #expect(HtmlClipSanitizer.sanitize("<p>Hẹn 3h 🙂</p>") == "<p>Hẹn 3h 🙂</p>")
    }
}
