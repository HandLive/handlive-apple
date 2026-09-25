import Foundation
import Testing

@Suite("Generated String Catalogs and accessors")
struct GeneratedFilesTests {
    @Test("generate-strings.py --check: every generated file matches ui-strings.json")
    func generatorCheck() throws {
        let process = Process()
        process.executableURL = WorkspaceFiles.python
        process.arguments = [WorkspaceFiles.generator.path, "--check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let log = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "\(log)")
    }

    @Test("Localizable.xcstrings: source en, every Apple key in en and vi with the same placeholders")
    func localizableCatalog() throws {
        let document = try WorkspaceFiles.json(WorkspaceFiles.localizableCatalog)
        #expect(document["sourceLanguage"] as? String == "en")
        #expect(document["version"] as? String == "1.0")
        let strings = document["strings"] as? [String: [String: Any]] ?? [:]
        let apple = try CatalogEntry.all().filter(\.isApple)
        #expect(Set(strings.keys) == Set(apple.map(\.key)))
        for entry in apple {
            let localizations = strings[entry.key]?["localizations"] as? [String: Any] ?? [:]
            #expect(Set(localizations.keys) == ["en", "vi"], "\(entry.key)")
            let specifiers = localizations.mapValues { Self.specifiers(in: $0) }
            #expect(specifiers["en"] == specifiers["vi"], "\(entry.key)")
            #expect(specifiers["en"]?.count == entry.args.count, "\(entry.key)")
        }
    }

    @Test("Purpose strings: InfoPlist.xcstrings in en and vi, Info.plist in en")
    func purposeStrings() throws {
        let plistEntries = try CatalogEntry.all().filter { $0.plistKey != nil && $0.platforms.contains("macos") }
        let keys = Set(plistEntries.compactMap(\.plistKey))
        #expect(keys.isSuperset(of: [
            "NSLocalNetworkUsageDescription", "NSMicrophoneUsageDescription", "NSFocusStatusUsageDescription",
        ]))
        let catalog = try WorkspaceFiles.json(WorkspaceFiles.appInfoPlistCatalog)["strings"] as? [String: [String: Any]]
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: WorkspaceFiles.appInfoPlist), format: nil) as? [String: Any] ?? [:]
        for entry in plistEntries {
            let plistKey = try #require(entry.plistKey)
            let localizations = catalog?[plistKey]?["localizations"] as? [String: [String: [String: String]]]
            for language in ["en", "vi"] {
                #expect(localizations?[language]?["stringUnit"]?["value"] == entry.texts[language] as? String,
                        "\(plistKey) [\(language)]")
            }
            #expect(info[plistKey] as? String == entry.texts["en"] as? String, "\(plistKey) in Info.plist")
        }
        #expect(info["NSBonjourServices"] as? [String] == ["_handlive._tcp"])
    }

    /// Sorted positional specifiers (`%1$@`, `%2$lld`) of every string unit under a localization.
    static func specifiers(in localization: Any) -> [String] {
        var units: [String] = []
        func collect(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let unit = dict["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                    units.append(value)
                }
                dict.values.forEach(collect)
            }
        }
        collect(localization)
        let pattern = try? NSRegularExpression(pattern: "%[0-9]+\\$(@|lld|f)")
        let found = units.flatMap { unit in
            pattern?.matches(in: unit, range: NSRange(unit.startIndex..., in: unit)).compactMap {
                Range($0.range, in: unit).map { String(unit[$0]) }
            } ?? []
        }
        return Array(Set(found)).sorted()
    }
}
