import Foundation
import Testing

/// 0.12.5 (Apple): no user-facing text is written in code outside the generated accessors. Scans every Swift source
/// of the apps and packages (tests and generated files excepted) for UI calls whose text is a string literal.
@Suite("No hard-coded UI text")
struct HardcodedTextScanTests {
    /// A SwiftUI/AppKit call whose first argument is a literal containing a letter, or a text property assigned
    /// a literal. `Text(verbatim:)` (user content) and `#Preview("…")` (developer names) are not UI text.
    static let patterns: [String] = [
        #"(?<![A-Za-z#])(Text|Button|Label|Toggle|Picker|Section|Menu|Link|MenuBarExtra|Window|WindowGroup|"#
            + #"LabeledContent|TextField|SecureField|ProgressView|GroupBox|DisclosureGroup|GroupedSection|"#
            + #"GroupedRowLabel|GroupedActionRow)\(\s*"[^"]*\p{L}"#,
        #"\.(help|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|alert|"#
            + #"confirmationDialog|badge)\(\s*"[^"]*\p{L}"#,
        #"\b(title|subtitle|messageText|informativeText|body|toolTip|placeholderString|label)\s*=\s*"[^"]*\p{L}"#,
        #"NSMenuItem\(\s*title:\s*"[^"]*\p{L}"#,
        // Any literal written in Vietnamese is UI text (Vietnamese letters and tone marks).
        #""[^"]*[ăâđêôơưĂÂĐÊÔƠƯ\x{1EA0}-\x{1EF9}\x{00C0}-\x{00C3}\x{00C8}-\x{00CA}\x{00CC}\x{00CD}\x{00D2}-\x{00D5}"#
            + #"\x{00D9}\x{00DA}\x{00DD}\x{00E0}-\x{00E3}\x{00E8}-\x{00EA}\x{00EC}\x{00ED}\x{00F2}-\x{00F5}"#
            + #"\x{00F9}\x{00FA}\x{00FD}\x{0128}\x{0129}\x{0168}\x{0169}][^"]*""#,
    ]

    static func sourceFiles() -> [URL] {
        let apple = WorkspaceFiles.appleRoot
        var roots = [apple.appendingPathComponent("macOS"), apple.appendingPathComponent("iOS")]
        let packages = (try? FileManager.default.contentsOfDirectory(
            at: apple.appendingPathComponent("Packages"), includingPropertiesForKeys: nil)) ?? []
        roots += packages.map { $0.appendingPathComponent("Sources") }
        return roots.flatMap { root -> [URL] in
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).filter {
                $0.pathExtension == "swift" && !$0.path.contains("/Generated/") && !$0.path.contains("/.build/")
            }
        }
    }

    @Test("UI calls take text from L10n, not from string literals")
    func noLiteralUIText() throws {
        let expressions = try Self.patterns.map { try NSRegularExpression(pattern: $0) }
        let files = Self.sourceFiles()
        #expect(files.count > 10)
        var findings: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, fullLine) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = fullLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("#Preview") { continue }
                // Drop a trailing comment (` // …`); comments are not UI text.
                let line = fullLine.components(separatedBy: " // ").first ?? fullLine
                let range = NSRange(line.startIndex..., in: line)
                if expressions.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                    findings.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
                }
            }
        }
        #expect(findings.isEmpty, "\(findings.joined(separator: "\n"))")
    }
}
